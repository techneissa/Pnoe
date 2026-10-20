import SwiftData
import XCTest

/// A clock the tests move by hand, so "later" is never a matter of waiting.
final class SyncTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_790_000_000)

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// One fake Mac: its own in-memory dictionary store, its own remembered sync state, and the shared
/// folder standing in for iCloud Drive.
@MainActor
final class SyncTestMac {
    let container: ModelContainer
    let engine: DictionarySyncEngine
    let clock: SyncTestClock

    init(drive: FolderDrive, stateFile: URL, clock: SyncTestClock) throws {
        let schema = Schema([VocabularyWord.self, WordReplacement.self, Snippet.self])
        container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(UUID().uuidString, schema: schema, isStoredInMemoryOnly: true))
        self.clock = clock
        engine = DictionarySyncEngine(
            store: DictionarySyncStore(modelContainer: container),
            drive: drive,
            stateFile: DictionarySyncLocalStateFile(url: stateFile),
            clock: { clock.now })
    }

    /// What the controller's debounced pass does when the drive can't be reached: notice the edit.
    func noteChanges() async throws {
        try await engine.recordLocalChanges()
    }

    @discardableResult
    func sync() async throws -> DictionarySyncReport {
        try await engine.run()
    }

    private func context() -> ModelContext { ModelContext(container) }

    // MARK: Vocabulary

    func addWord(_ term: String) throws {
        let context = context()
        context.insert(VocabularyWord(word: term, dateAdded: clock.now))
        try context.save()
    }

    func removeWord(_ term: String) throws {
        let context = context()
        for word in try context.fetch(FetchDescriptor<VocabularyWord>()) where word.word == term {
            context.delete(word)
        }
        try context.save()
    }

    func words() throws -> [String] {
        try context().fetch(FetchDescriptor<VocabularyWord>()).map(\.word).sorted()
    }

    // MARK: Replacements

    func addReplacement(_ sources: String, to destination: String) throws {
        let context = context()
        context.insert(WordReplacement(originalText: sources, replacementText: destination, dateAdded: clock.now))
        try context.save()
    }

    func editReplacement(to destination: String, sources: String? = nil, newDestination: String? = nil) throws {
        let context = context()
        for rule in try context.fetch(FetchDescriptor<WordReplacement>()) where rule.replacementText == destination {
            if let sources { rule.originalText = sources }
            if let newDestination { rule.replacementText = newDestination }
        }
        try context.save()
    }

    func removeReplacement(to destination: String) throws {
        let context = context()
        for rule in try context.fetch(FetchDescriptor<WordReplacement>()) where rule.replacementText == destination {
            context.delete(rule)
        }
        try context.save()
    }

    func replacements() throws -> [String] {
        try context().fetch(FetchDescriptor<WordReplacement>())
            .map { "\($0.originalText) → \($0.replacementText)" }.sorted()
    }

    func replacementIDs() throws -> [UUID] {
        try context().fetch(FetchDescriptor<WordReplacement>()).map(\.id)
    }

    // MARK: Snippets

    func addSnippet(_ trigger: String, _ expansion: String) throws {
        let context = context()
        context.insert(Snippet(trigger: trigger, expansion: expansion, dateAdded: clock.now))
        try context.save()
    }

    func editSnippet(_ trigger: String, expansion: String) throws {
        let context = context()
        for snippet in try context.fetch(FetchDescriptor<Snippet>()) where snippet.trigger == trigger {
            snippet.expansion = expansion
        }
        try context.save()
    }

    func removeSnippet(_ trigger: String) throws {
        let context = context()
        for snippet in try context.fetch(FetchDescriptor<Snippet>()) where snippet.trigger == trigger {
            context.delete(snippet)
        }
        try context.save()
    }

    func snippets() throws -> [String] {
        try context().fetch(FetchDescriptor<Snippet>()).map { "\($0.trigger)=\($0.expansion)" }.sorted()
    }
}

@MainActor
final class DictionarySyncTests: XCTestCase {
    private var directory: URL!
    private var driveRoot: URL!
    private var drive: FolderDrive!
    private var clock: SyncTestClock!
    private var stateCounter = 0

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pnoe-drive-sync-\(UUID().uuidString)", isDirectory: true)
        driveRoot = directory.appendingPathComponent("drive", isDirectory: true)
        try FileManager.default.createDirectory(at: driveRoot, withIntermediateDirectories: true)
        drive = FolderDrive(root: driveRoot)
        clock = SyncTestClock()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeMac() throws -> SyncTestMac {
        stateCounter += 1
        return try SyncTestMac(
            drive: drive, stateFile: directory.appendingPathComponent("state-\(stateCounter).json"), clock: clock)
    }

    private var syncFile: URL { drive.fileURL }

    private func advance(_ seconds: TimeInterval = 10) { clock.advance(seconds) }

    // MARK: Add, edit, delete

    func testItemsAddedOnOneMacAppearOnTheOther() async throws {
        let a = try makeMac()
        let b = try makeMac()
        try a.addWord("Pnoe")
        try a.addReplacement("teh, adn", to: "the")
        try a.addSnippet("my email", "sam@example.com")

        try await a.sync()
        XCTAssertTrue(FileManager.default.fileExists(atPath: syncFile.path))
        advance()
        try await b.sync()

        XCTAssertEqual(try b.words(), ["Pnoe"])
        XCTAssertEqual(try b.replacements(), ["teh, adn → the"])
        XCTAssertEqual(try b.snippets(), ["my email=sam@example.com"])
        XCTAssertEqual(try a.replacementIDs(), try b.replacementIDs(), "the id travels with the item")
    }

    func testEditsReachTheOtherMac() async throws {
        let a = try makeMac()
        let b = try makeMac()
        try a.addReplacement("teh", to: "the")
        try a.addSnippet("sig", "Best,\nSam")
        try a.addWord("Kubernetes")
        try await a.sync()
        advance()
        try await b.sync()

        advance()
        try b.editReplacement(to: "the", sources: "teh, thee")
        try b.editSnippet("sig", expansion: "Regards,\nSam")
        advance()
        try await b.sync()
        advance()
        try await a.sync()

        XCTAssertEqual(try a.replacements(), ["teh, thee → the"])
        XCTAssertEqual(try a.snippets(), ["sig=Regards,\nSam"])
        XCTAssertEqual(try a.words(), ["Kubernetes"])
        XCTAssertEqual(try a.replacementIDs().count, 1, "an edit never duplicates the item")
    }

    func testDeletionsReachTheOtherMacAndStayDeleted() async throws {
        let a = try makeMac()
        let b = try makeMac()
        try a.addWord("Pnoe")
        try a.addWord("Gone")
        try a.addReplacement("teh", to: "the")
        try a.addSnippet("sig", "Best")
        try await a.sync()
        advance()
        try await b.sync()

        advance()
        try b.removeWord("Gone")
        try b.removeReplacement(to: "the")
        try b.removeSnippet("sig")
        try await b.sync()
        advance()
        try await a.sync()

        XCTAssertEqual(try a.words(), ["Pnoe"])
        XCTAssertEqual(try a.replacements(), [])
        XCTAssertEqual(try a.snippets(), [])

        // Neither Mac brings them back on later passes.
        advance()
        try await a.sync()
        advance()
        try await b.sync()
        XCTAssertEqual(try b.words(), ["Pnoe"])
        XCTAssertEqual(try b.replacements(), [])
        XCTAssertEqual(try b.snippets(), [])

        let archive = try DictionaryImportExportService.decodeArchiveData(Data(contentsOf: syncFile)).archive
        XCTAssertEqual(archive.sync?.tombstones.count, 3, "the deletions stay in the file for the other Macs")
    }

    func testWordDeletedAndTypedAgainComesBack() async throws {
        let a = try makeMac()
        let b = try makeMac()
        try a.addWord("Pnoe")
        try await a.sync()
        advance()
        try await b.sync()
        advance()
        try a.removeWord("Pnoe")
        try await a.sync()
        advance()
        try await b.sync()
        XCTAssertEqual(try b.words(), [])

        advance()
        try b.addWord("Pnoe")
        try await b.sync()
        advance()
        try await a.sync()
        XCTAssertEqual(try a.words(), ["Pnoe"])
        XCTAssertEqual(try b.words(), ["Pnoe"])
    }

    func testPassWithNothingNewLeavesTheFileAlone() async throws {
        let a = try makeMac()
        try a.addWord("Pnoe")
        let first = try await a.sync()
        XCTAssertTrue(first.wroteFile)
        let before = try Data(contentsOf: syncFile)

        advance()
        let second = try await a.sync()
        XCTAssertFalse(second.wroteFile)
        XCTAssertEqual(try Data(contentsOf: syncFile), before)
    }

    // MARK: Conflicts

    func testConcurrentEditsNewestWins() async throws {
        let a = try makeMac()
        let b = try makeMac()
        try a.addSnippet("sig", "Best")
        try await a.sync()
        advance()
        try await b.sync()

        advance()
        try a.editSnippet("sig", expansion: "from A")
        try await a.noteChanges()
        advance(20)
        try b.editSnippet("sig", expansion: "from B")
        try await b.noteChanges()

        // B edited last, whichever Mac syncs first.
        try await b.sync()
        advance()
        try await a.sync()
        advance()
        try await b.sync()
        XCTAssertEqual(try a.snippets(), ["sig=from B"])
        XCTAssertEqual(try b.snippets(), ["sig=from B"])
    }

    func testConcurrentEditsNewestWinsWhenTheOlderOneSyncsLast() async throws {
        let a = try makeMac()
        let b = try makeMac()
        try a.addSnippet("sig", "Best")
        try await a.sync()
        advance()
        try await b.sync()

        advance()
        try b.editSnippet("sig", expansion: "from B")
        try await b.noteChanges()
        advance(20)
        try a.editSnippet("sig", expansion: "from A")
        try await a.noteChanges()

        try await a.sync()
        advance()
        try await b.sync()
        advance()
        try await a.sync()
        XCTAssertEqual(try a.snippets(), ["sig=from A"])
        XCTAssertEqual(try b.snippets(), ["sig=from A"])
    }

    func testEditMadeWhileDriveWasOffKeepsTheTimeItWasMade() async throws {
        let a = try makeMac()
        let b = try makeMac()
        try a.addSnippet("sig", "Best")
        try await a.sync()
        advance()
        try await b.sync()

        // A loses the drive and edits; the failed pass still notes the time of the edit.
        let away = directory.appendingPathComponent("drive-away", isDirectory: true)
        try FileManager.default.moveItem(at: driveRoot, to: away)
        advance()
        try a.editSnippet("sig", expansion: "from A")
        do {
            try await a.sync()
            XCTFail("the drive is gone")
        } catch {
            XCTAssertEqual(error as? DictionarySyncError, .driveUnavailable)
        }

        // The drive is back for B, which edits later and syncs at once.
        try FileManager.default.moveItem(at: away, to: driveRoot)
        advance(20)
        try b.editSnippet("sig", expansion: "from B")
        try await b.sync()

        // A gets the drive back a long time after its edit; B's edit is still the newer one.
        advance(3000)
        try await a.sync()
        XCTAssertEqual(try a.snippets(), ["sig=from B"])
        XCTAssertEqual(try b.snippets(), ["sig=from B"])
    }

    func testDeletionBeatsAnOlderEditAndALaterEditBeatsTheDeletion() async throws {
        let a = try makeMac()
        let b = try makeMac()
        try a.addSnippet("old", "x")
        try a.addSnippet("new", "x")
        try await a.sync()
        advance()
        try await b.sync()

        // An edit counts from the pass that carries it, so each side syncs right after its change.
        advance()
        try b.editSnippet("old", expansion: "edited before the delete")
        try await b.sync()
        advance(20)
        try a.removeSnippet("old")
        try a.removeSnippet("new")
        try await a.sync()
        advance(20)
        try b.editSnippet("new", expansion: "edited after the delete")
        advance()
        try await b.sync()
        advance()
        try await a.sync()

        XCTAssertEqual(try a.snippets(), ["new=edited after the delete"])
        XCTAssertEqual(try b.snippets(), ["new=edited after the delete"])
    }

    func testTombstonesLastNinetyDays() {
        let day: TimeInterval = 24 * 60 * 60
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let young = DictionarySyncKey.vocabulary(term: "young")
        let old = DictionarySyncKey.vocabulary(term: "old")
        var state = DictionarySyncState()
        state.tombstones[young] = now.addingTimeInterval(-89 * day)
        state.tombstones[old] = now.addingTimeInterval(-91 * day)

        let merged = DictionarySyncMerge.merge(state, DictionarySyncState(), now: now)
        XCTAssertNotNil(merged.tombstones[young])
        XCTAssertNil(merged.tombstones[old])
    }

    func testMergeDoesNotDependOnTheOrderAndSettlesAtOnce() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func record(_ id: String, _ trigger: String, _ expansion: String, at seconds: TimeInterval)
            -> DictionarySyncRecord
        {
            DictionarySyncRecord(
                key: DictionarySyncKey(kind: .snippet, id: id),
                payload: .snippet(trigger: trigger, expansion: expansion),
                createdAt: now.addingTimeInterval(-1000), modifiedAt: now.addingTimeInterval(seconds))
        }
        var a = DictionarySyncState()
        var b = DictionarySyncState()
        let one = record("00000000-0000-0000-0000-000000000001", "sig", "A", at: -50)
        let two = record("00000000-0000-0000-0000-000000000002", "SIG", "B", at: -40)
        let three = record("00000000-0000-0000-0000-000000000003", "other", "C", at: -30)
        a.records[one.key] = one
        a.records[three.key] = three
        b.records[two.key] = two
        b.tombstones[three.key] = now.addingTimeInterval(-10)

        let ab = DictionarySyncMerge.merge(a, b, now: now)
        let ba = DictionarySyncMerge.merge(b, a, now: now)
        XCTAssertEqual(ab, ba)
        XCTAssertEqual(DictionarySyncMerge.merge(ab, a, now: now), ab)
        XCTAssertEqual(DictionarySyncMerge.merge(ab, b, now: now), ab)
        XCTAssertEqual(ab.records.count, 1, "the two sig snippets became one, other was deleted")
        XCTAssertEqual(ab.records[one.key]?.payload, .snippet(trigger: "SIG", expansion: "B"))
    }

    func testTwoRulesCannotShareASourceWord() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let first = DictionarySyncRecord(
            key: DictionarySyncKey(kind: .replacement, id: "00000000-0000-0000-0000-00000000000A"),
            payload: .replacement(sources: ["tea"], replacement: "Tea"),
            createdAt: now.addingTimeInterval(-100), modifiedAt: now.addingTimeInterval(-100))
        let second = DictionarySyncRecord(
            key: DictionarySyncKey(kind: .replacement, id: "00000000-0000-0000-0000-00000000000B"),
            payload: .replacement(sources: ["TEA", "chai"], replacement: "Chai"),
            createdAt: now.addingTimeInterval(-50), modifiedAt: now.addingTimeInterval(-50))
        var a = DictionarySyncState()
        a.records[first.key] = first
        var b = DictionarySyncState()
        b.records[second.key] = second

        let merged = DictionarySyncMerge.merge(a, b, now: now)
        XCTAssertEqual(merged.records[first.key]?.payload, .replacement(sources: ["tea"], replacement: "Tea"))
        XCTAssertEqual(merged.records[second.key]?.payload, .replacement(sources: ["chai"], replacement: "Chai"))
        XCTAssertEqual(DictionarySyncMerge.merge(merged, a, now: now), merged)
    }

    // MARK: First switch-on

    func testFirstSyncOfTwoNonEmptyMacsMergesWithoutLosingOrDuplicating() async throws {
        let a = try makeMac()
        let b = try makeMac()
        try a.addWord("Zeta")
        try a.addWord("Shared")
        try a.addReplacement("teh", to: "the")
        try a.addReplacement("kube", to: "Kubernetes")
        try a.addSnippet("my email", "old@example.com")
        try a.addSnippet("only a", "A")
        advance()
        try b.addWord("Beta")
        try b.addWord("shared")
        try b.addReplacement("adn", to: "the")
        try b.addReplacement("recieve", to: "receive")
        try b.addSnippet("My Email", "new@example.com")
        try b.addSnippet("only b", "B")
        advance()

        try await a.sync()
        advance()
        try await b.sync()
        advance()
        try await a.sync()
        advance()
        try await b.sync()

        for mac in [a, b] {
            XCTAssertEqual(try mac.words().map { $0.lowercased() }.sorted(), ["beta", "shared", "zeta"])
            XCTAssertEqual(
                try mac.replacements(), ["kube → Kubernetes", "recieve → receive", "teh, adn → the"],
                "the two rules for the same text became one with both source words")
            XCTAssertEqual(
                try mac.snippets().filter { $0.lowercased().hasPrefix("my email") }.map { $0.lowercased() },
                ["my email=new@example.com"], "one snippet per trigger, the newer text")
            XCTAssertEqual(try mac.snippets().count, 3)
        }
        XCTAssertEqual(try a.replacementIDs().sorted { $0.uuidString < $1.uuidString },
                       try b.replacementIDs().sorted { $0.uuidString < $1.uuidString })
    }

    func testFirstSyncIntoAnExistingFileKeepsEverythingOnBothSides() async throws {
        let a = try makeMac()
        try a.addWord("FromA")
        try await a.sync()
        advance()

        let b = try makeMac()
        try b.addWord("FromB")
        try await b.sync()
        XCTAssertEqual(try b.words(), ["FromA", "FromB"])
        advance()
        try await a.sync()
        XCTAssertEqual(try a.words(), ["FromA", "FromB"])
    }

    // MARK: Files that can't be used

    func testMalformedFileIsNeverOverwritten() async throws {
        let a = try makeMac()
        try a.addWord("Pnoe")
        try FileManager.default.createDirectory(at: drive.folderURL, withIntermediateDirectories: true)
        let garbage = Data("{ this is not json".utf8)
        try garbage.write(to: syncFile)

        do {
            try await a.sync()
            XCTFail("an unreadable file must stop the pass")
        } catch {
            XCTAssertEqual(error as? DictionarySyncError, .unreadableFile)
        }
        XCTAssertEqual(try Data(contentsOf: syncFile), garbage)
        XCTAssertEqual(try a.words(), ["Pnoe"], "the local dictionary is untouched")
    }

    func testFileOfAnotherFormatOrNewerVersionIsLeftAlone() async throws {
        let a = try makeMac()
        try a.addWord("Pnoe")
        try FileManager.default.createDirectory(at: drive.folderURL, withIntermediateDirectories: true)

        for json in [
            #"{"format":"something.else","schemaVersion":1}"#,
            #"{"format":"pnoe.dictionary","schemaVersion":99,"exportedAt":"2026-10-01T00:00:00Z","vocabulary":[],"replacements":[]}"#,
            #"{"format":"pnoe.dictionary","schemaVersion":1,"vocabulary":"nope"}"#,
        ] {
            let data = Data(json.utf8)
            try data.write(to: syncFile)
            do {
                try await a.sync()
                XCTFail("must not read \(json)")
            } catch {
                XCTAssertEqual(error as? DictionarySyncError, .unreadableFile)
            }
            XCTAssertEqual(try Data(contentsOf: syncFile), data)
        }
    }

    func testFileStillInICloudIsAskedForAndNothingIsTouched() async throws {
        let b = try makeMac()
        try b.addWord("FromB")
        try await b.sync()

        // iCloud keeps a stub named `.<file>.icloud` until the file is downloaded.
        let stub = drive.folderURL.appendingPathComponent(".\(FolderDrive.fileName).icloud")
        let held = directory.appendingPathComponent("held.json")
        try FileManager.default.moveItem(at: syncFile, to: held)
        try Data("stub".utf8).write(to: stub)

        let a = try makeMac()
        try a.addWord("FromA")
        do {
            try await a.sync()
            XCTFail("a file that is not on this Mac yet must not be merged or replaced")
        } catch {
            XCTAssertEqual(error as? DictionarySyncError, .notDownloaded)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: syncFile.path))
        XCTAssertEqual(try a.words(), ["FromA"])

        // The download finished.
        try FileManager.default.removeItem(at: stub)
        try FileManager.default.moveItem(at: held, to: syncFile)
        advance()
        try await a.sync()
        XCTAssertEqual(try a.words(), ["FromA", "FromB"])
    }

    func testDriveOffKeepsEverythingAndSyncsWhenItIsBack() async throws {
        let missing = directory.appendingPathComponent("no-drive", isDirectory: true)
        let offline = try SyncTestMac(
            drive: FolderDrive(root: missing), stateFile: directory.appendingPathComponent("offline.json"),
            clock: clock)
        try offline.addWord("Pnoe")
        do {
            try await offline.sync()
            XCTFail("no iCloud Drive folder means no pass")
        } catch {
            XCTAssertEqual(error as? DictionarySyncError, .driveUnavailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "nothing is created for a missing drive")
        XCTAssertEqual(try offline.words(), ["Pnoe"])

        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        try await offline.sync()
        XCTAssertTrue(FileManager.default.fileExists(atPath: missing.appendingPathComponent("Pnoe/\(FolderDrive.fileName)").path))
    }

    // MARK: Format

    func testSyncFileStaysReadableByTheManualImport() async throws {
        let a = try makeMac()
        try a.addWord("Pnoe")
        try a.addReplacement("teh, adn", to: "the")
        try await a.sync()

        let archive = try DictionaryImportExportService.decodeArchiveData(Data(contentsOf: syncFile)).archive
        XCTAssertEqual(archive.format, DictionaryArchive.formatIdentifier)
        XCTAssertEqual(archive.schemaVersion, 1)
        XCTAssertEqual(archive.vocabulary.map(\.term), ["Pnoe"])
        XCTAssertEqual(archive.replacements.first?.sources, ["teh", "adn"])
        XCTAssertNotNil(archive.replacements.first?.id)
        XCTAssertNotNil(archive.replacements.first?.modifiedAt)
        XCTAssertNotNil(archive.sync?.deviceID)
    }

    func testPlainExportWithoutIdsMergesWithTheSameIdsOnEveryMac() throws {
        let archive = DictionaryArchive(
            vocabulary: [DictionaryVocabularyEntry(term: "Pnoe", createdAt: nil)],
            replacements: [DictionaryReplacementEntry(sources: ["teh"], replacement: "the", createdAt: Date())])
        let first = DictionarySyncFormat.state(from: archive)
        let second = DictionarySyncFormat.state(from: archive)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.records.count, 2)
    }

    // MARK: Local changes

    func testCaptureStampsEditsAndDeletionsAndKeepsUntouchedItems() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let t1 = t0.addingTimeInterval(100)
        let kept = DictionarySyncItem(
            key: DictionarySyncKey(kind: .snippet, id: "k"), payload: .snippet(trigger: "a", expansion: "1"),
            createdAt: t0)
        let edited = DictionarySyncItem(
            key: DictionarySyncKey(kind: .snippet, id: "e"), payload: .snippet(trigger: "b", expansion: "1"),
            createdAt: t0)
        let removed = DictionarySyncItem(
            key: DictionarySyncKey(kind: .snippet, id: "r"), payload: .snippet(trigger: "c", expansion: "1"),
            createdAt: t0)
        let last = DictionarySyncMerge.capture(current: [kept, edited, removed], last: .init(), now: t0)

        let editedNow = DictionarySyncItem(
            key: edited.key, payload: .snippet(trigger: "b", expansion: "2"), createdAt: t0)
        let state = DictionarySyncMerge.capture(current: [kept, editedNow], last: last, now: t1)

        XCTAssertEqual(state.records[kept.key]?.modifiedAt, t0)
        XCTAssertEqual(state.records[edited.key]?.modifiedAt, t1)
        XCTAssertNil(state.records[removed.key])
        XCTAssertEqual(state.tombstones[removed.key], t1)
    }

    func testAnItemChangedWhileThePassRanIsLeftForTheNextPass() async throws {
        let a = try makeMac()
        try a.addSnippet("sig", "Best")
        let store = DictionarySyncStore(modelContainer: a.container)
        let captured = try await store.capture(last: .init(), now: clock.now)

        // The user edits and removes things after the capture.
        try a.editSnippet("sig", expansion: "Typed meanwhile")
        try a.addWord("Late")
        var merged = captured
        merged.records = merged.records.mapValues {
            var record = $0
            record.payload = .snippet(trigger: "sig", expansion: "From elsewhere")
            return record
        }
        try await store.apply(merged: merged, local: captured)

        XCTAssertEqual(try a.snippets(), ["sig=Typed meanwhile"])
        XCTAssertEqual(try a.words(), ["Late"])
    }
}
