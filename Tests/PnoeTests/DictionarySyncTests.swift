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

/// The identity token of a fake Mac's store; changing it is what a reset or restored store looks like.
final class SyncTestToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = UUID().uuidString

    var current: String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func reset() {
        lock.lock()
        value = UUID().uuidString
        lock.unlock()
    }
}

/// Versions of the sync file that iCloud kept apart, made by hand.
final class FakeConflictVersions: SyncConflictVersionProvider, @unchecked Sendable {
    final class Version: SyncConflictVersion, @unchecked Sendable {
        let data: Data
        private(set) var isResolved = false

        init(_ data: Data) { self.data = data }

        func contents() throws -> Data { data }
        func markResolvedAndRemove() throws { isResolved = true }
    }

    var versions: [Version] = []

    func unresolvedVersions(of url: URL) -> [any SyncConflictVersion] {
        versions.filter { !$0.isResolved }
    }
}

/// One fake Mac: its own in-memory dictionary store, its own remembered sync state, and the shared
/// file standing in for the sync file in iCloud Drive.
@MainActor
final class SyncTestMac {
    let container: ModelContainer
    let engine: DictionarySyncEngine
    let clock: SyncTestClock
    let token = SyncTestToken()

    init(drive: any DictionarySyncDrive, stateFile: URL, clock: SyncTestClock, token: SyncTestToken? = nil) throws {
        let schema = Schema([VocabularyWord.self, WordReplacement.self, Snippet.self])
        container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(UUID().uuidString, schema: schema, isStoredInMemoryOnly: true))
        self.clock = clock
        let identity = token ?? self.token
        engine = DictionarySyncEngine(
            store: DictionarySyncStore(modelContainer: container),
            drive: drive,
            stateFile: DictionarySyncLocalStateFile(url: stateFile),
            storeIdentity: { identity.current },
            clock: { clock.now })
    }

    /// What Sync now does: plan, then commit with every shown removal confirmed.
    @discardableResult
    func sync(
        _ removals: DictionarySyncDeletionChoice = .remove, conflicts: DictionarySyncConflictChoice = .thisMac
    ) async throws -> DictionarySyncReport {
        let plan = try await engine.plan()
        return try await engine.commit(
            answer: DictionarySyncAnswer(removals: removals, conflicts: conflicts), reviewed: plan.reviewedKeys)
    }

    func plan() async throws -> DictionarySyncPlan {
        try await engine.plan()
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

    func setReplacementEnabled(to destination: String, _ isEnabled: Bool) throws {
        let context = context()
        for rule in try context.fetch(FetchDescriptor<WordReplacement>()) where rule.replacementText == destination {
            rule.isEnabled = isEnabled
        }
        try context.save()
    }

    func replacementStates() throws -> [String: Bool] {
        Dictionary(
            uniqueKeysWithValues: try context().fetch(FetchDescriptor<WordReplacement>())
                .map { ($0.replacementText, $0.isEnabled) })
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
    private var folder: URL!
    private var syncFile: URL!
    private var drive: SyncFileDrive!
    private var clock: SyncTestClock!
    private var stateCounter = 0

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pnoe-drive-sync-\(UUID().uuidString)", isDirectory: true)
        folder = directory.appendingPathComponent("drive/Pnoe", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        syncFile = folder.appendingPathComponent("Dictionary Sync.json")
        drive = SyncFileDrive(fileURL: syncFile)
        clock = SyncTestClock()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeMac(drive: (any DictionarySyncDrive)? = nil, stateFile: URL? = nil, token: SyncTestToken? = nil)
        throws -> SyncTestMac
    {
        stateCounter += 1
        return try SyncTestMac(
            drive: drive ?? self.drive,
            stateFile: stateFile ?? directory.appendingPathComponent("state-\(stateCounter).json"),
            clock: clock, token: token)
    }

    private func advance(_ seconds: TimeInterval = 10) { clock.advance(seconds) }

    private let day: TimeInterval = 24 * 60 * 60

    private func fileArchive() throws -> DictionaryArchive {
        try DictionaryImportExportService.decodeArchiveData(Data(contentsOf: syncFile)).archive
    }

    private func fileState() throws -> DictionarySyncState {
        DictionarySyncFormat.unclampedState(from: try fileArchive())
    }

    private func write(_ state: DictionarySyncState) throws {
        try DictionarySyncFormat.encode(state, deviceID: "other-mac", now: clock.now).write(to: syncFile)
    }

    private func wordRecord(_ term: String, at date: Date) -> DictionarySyncRecord {
        DictionarySyncRecord(
            key: .vocabulary(term: term), payload: .vocabulary(term: term), createdAt: date, modifiedAt: date)
    }

    // MARK: Add, edit, delete

    func testItemsAddedOnOneMacAppearOnTheOther() async throws {
        let a = try makeMac()
        let b = try makeMac()
        try a.addWord("Pnoe")
        try a.addReplacement("teh, adn", to: "the")
        try a.addSnippet("my email", "sam@example.com")

        let report = try await a.sync()
        XCTAssertTrue(report.wroteFile)
        XCTAssertEqual(report.added, 0)
        advance()
        let second = try await b.sync()
        XCTAssertEqual(second.added, 3)

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
        let pushed = try await b.sync()
        XCTAssertEqual(pushed.updated, 0)
        advance()
        let pulled = try await a.sync()
        XCTAssertEqual(pulled.updated, 2)

        XCTAssertEqual(try a.replacements(), ["teh, thee → the"])
        XCTAssertEqual(try a.snippets(), ["sig=Regards,\nSam"])
        XCTAssertEqual(try a.words(), ["Kubernetes"])
        XCTAssertEqual(try a.replacementIDs().count, 1, "an edit never duplicates the item")
    }

    func testDeletionsReachTheOtherMacAfterTheyAreShownAndStayDeleted() async throws {
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

        let plan = try await a.plan()
        XCTAssertEqual(plan.removals.count, 3)
        XCTAssertEqual(Set(plan.removals.map(\.title)), ["Gone", "teh → the", "sig"])
        XCTAssertEqual(Set(plan.removals.map(\.reason)), [.deletedElsewhere])
        XCTAssertEqual(try a.words(), ["Gone", "Pnoe"], "planning changes nothing")

        let report = try await a.engine.commit(answer: .init(removals: .remove), reviewed: plan.reviewedKeys)
        XCTAssertEqual(report.removed, 3)
        XCTAssertEqual(try a.words(), ["Pnoe"])
        XCTAssertEqual(try a.replacements(), [])
        XCTAssertEqual(try a.snippets(), [])

        advance()
        try await a.sync()
        advance()
        try await b.sync()
        XCTAssertEqual(try b.words(), ["Pnoe"])
        XCTAssertEqual(try fileArchive().sync?.tombstones.count, 3, "the deletions stay in the file")
    }

    func testKeepThemKeepsTheEntriesAndPutsThemBack() async throws {
        let a = try makeMac()
        let b = try makeMac()
        try a.addWord("Pnoe")
        try a.addWord("Keeper")
        try a.addSnippet("sig", "Best")
        try await a.sync()
        advance()
        try await b.sync()
        advance()
        try b.removeWord("Keeper")
        try b.removeSnippet("sig")
        try await b.sync()
        advance()

        let plan = try await a.plan()
        XCTAssertEqual(plan.removals.count, 2)
        let report = try await a.engine.commit(answer: .init(removals: .keep), reviewed: plan.reviewedKeys)
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(try a.words(), ["Keeper", "Pnoe"])
        XCTAssertEqual(try a.snippets(), ["sig=Best"])
        XCTAssertEqual(try fileState().tombstones.count, 0, "the entries are in the file again")

        advance()
        let back = try await b.sync()
        XCTAssertEqual(back.removed, 0)
        XCTAssertEqual(try b.words(), ["Keeper", "Pnoe"])
        XCTAssertEqual(try b.snippets(), ["sig=Best"])
    }

    func testRemovalsNotShownStopThePassAndChangeNothing() async throws {
        let a = try makeMac()
        let b = try makeMac()
        try a.addWord("Pnoe")
        try await a.sync()
        advance()
        try await b.sync()
        advance()
        try b.removeWord("Pnoe")
        try await b.sync()
        advance()

        do {
            _ = try await a.engine.commit(answer: .init(removals: .remove), reviewed: [])
            XCTFail("a removal the user was not asked about must stop the pass")
        } catch {
            XCTAssertEqual(error as? DictionarySyncError, .changedDuringReview)
        }
        XCTAssertEqual(try a.words(), ["Pnoe"])
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

    func testNewestEditWinsAndTheOlderMacTakesIt() async throws {
        let a = try makeMac()
        let b = try makeMac()
        try a.addSnippet("sig", "Best")
        try await a.sync()
        advance()
        try await b.sync()

        advance()
        try a.editSnippet("sig", expansion: "from A")
        try await a.sync()
        advance(20)
        try b.editSnippet("sig", expansion: "from B")
        let plan = try await b.plan()
        XCTAssertEqual(plan.conflicts.map(\.title), ["sig"], "B changed it and so did A since B's last pass")
        try await b.sync()
        advance()
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

    func testNewestRuleKeepsASharedSourceAndNoRuleLosesItsOnlySource() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func rule(_ id: String, _ sources: [String], _ destination: String, at seconds: TimeInterval)
            -> DictionarySyncRecord
        {
            DictionarySyncRecord(
                key: DictionarySyncKey(kind: .replacement, id: "00000000-0000-0000-0000-0000000000\(id)"),
                payload: .replacement(sources: sources, replacement: destination, isEnabled: true),
                createdAt: now.addingTimeInterval(seconds), modifiedAt: now.addingTimeInterval(seconds))
        }
        let older = rule("0A", ["tea", "green"], "Tea", at: -100)
        let newer = rule("0B", ["TEA", "chai"], "Chai", at: -50)
        let only = rule("0C", ["tea"], "Black", at: -200)
        var a = DictionarySyncState()
        a.records[older.key] = older
        a.records[only.key] = only
        var b = DictionarySyncState()
        b.records[newer.key] = newer

        let merged = DictionarySyncMerge.merge(a, b, now: now)
        XCTAssertEqual(merged.records[newer.key]?.payload, .replacement(sources: ["TEA", "chai"], replacement: "Chai", isEnabled: true))
        XCTAssertEqual(
            merged.records[older.key]?.payload, .replacement(sources: ["green"], replacement: "Tea", isEnabled: true),
            "the newest rule has the word; the older one keeps its other source")
        XCTAssertEqual(
            merged.records[only.key]?.payload, .replacement(sources: ["tea"], replacement: "Black", isEnabled: true),
            "a rule with only that source keeps it: nothing is lost")
        XCTAssertEqual(DictionarySyncMerge.merge(merged, a, now: now), merged)
        XCTAssertEqual(DictionarySyncMerge.merge(merged, b, now: now), merged)
    }

    // MARK: Changed on both Macs

    /// A and B share a snippet `sig`; A has edited it, B edited it and synced (the file is newer than A's
    /// edit, and A's pass comes later still: dates would silently pick A).
    private func bothMacsEditedTheSnippet() async throws -> (SyncTestMac, SyncTestMac) {
        let a = try makeMac()
        let b = try makeMac()
        try a.addSnippet("sig", "Best")
        try await a.sync()
        advance()
        try await b.sync()
        advance()
        try a.editSnippet("sig", expansion: "from A")
        advance()
        try b.editSnippet("sig", expansion: "from B")
        try await b.sync()
        advance(3600)
        return (a, b)
    }

    func testEntryChangedOnBothMacsShowsBothVersionsAndTheOtherMacsCanWin() async throws {
        let (a, _) = try await bothMacsEditedTheSnippet()
        let plan = try await a.plan()
        XCTAssertEqual(plan.conflicts.count, 1)
        XCTAssertEqual(plan.conflicts.first?.title, "sig")
        XCTAssertEqual(plan.conflicts.first?.thisMac, "from A")
        XCTAssertEqual(plan.conflicts.first?.otherMac, "from B")
        XCTAssertEqual(try a.snippets(), ["sig=from A"], "asking changes nothing")

        let before = try Data(contentsOf: syncFile)
        try await a.engine.commit(
            answer: DictionarySyncAnswer(conflicts: .otherMac), reviewed: plan.reviewedKeys)
        XCTAssertEqual(try a.snippets(), ["sig=from B"])
        XCTAssertEqual(try Data(contentsOf: syncFile), before, "the file already had the other Mac's version")
    }

    func testEntryChangedOnBothMacsKeepsThisMacsVersionByDefaultAndPutsItInTheFile() async throws {
        let (a, b) = try await bothMacsEditedTheSnippet()
        let plan = try await a.plan()
        try await a.engine.commit(answer: DictionarySyncAnswer(), reviewed: plan.reviewedKeys)
        XCTAssertEqual(try a.snippets(), ["sig=from A"])
        XCTAssertEqual(try fileArchive().snippets?.first?.expansion, "from A")

        advance()
        let next = try await b.plan()
        XCTAssertEqual(next.conflicts, [], "B changed nothing since, so it takes the file's version without asking")
        try await b.sync()
        XCTAssertEqual(try b.snippets(), ["sig=from A"])
    }

    func testEditedHereAndDeletedThereIsAskedAbout() async throws {
        let a = try makeMac()
        let b = try makeMac()
        try a.addSnippet("sig", "Best")
        try await a.sync()
        advance()
        try await b.sync()
        advance()
        try b.removeSnippet("sig")
        try await b.sync()
        advance(3600)
        try a.editSnippet("sig", expansion: "mine")

        let plan = try await a.plan()
        XCTAssertEqual(plan.removals, [], "an entry edited here is not a plain removal")
        XCTAssertEqual(plan.conflicts.map(\.title), ["sig"])
        XCTAssertEqual(plan.conflicts.first?.thisMac, "mine")
        XCTAssertNil(plan.conflicts.first?.otherMac, "deleted on the other Mac")

        try await a.engine.commit(answer: DictionarySyncAnswer(conflicts: .otherMac), reviewed: plan.reviewedKeys)
        XCTAssertEqual(try a.snippets(), [], "the other Mac's deletion, chosen")
    }

    func testEditedHereAndDeletedThereKeepsThisMacsEditByDefault() async throws {
        let a = try makeMac()
        let b = try makeMac()
        try a.addSnippet("sig", "Best")
        try await a.sync()
        advance()
        try await b.sync()
        advance()
        try b.removeSnippet("sig")
        try await b.sync()
        advance(3600)
        try a.editSnippet("sig", expansion: "mine")

        try await a.sync(.remove, conflicts: .thisMac)
        XCTAssertEqual(try a.snippets(), ["sig=mine"])
        XCTAssertEqual(try fileArchive().snippets?.first?.expansion, "mine")
        advance()
        try await b.sync()
        XCTAssertEqual(try b.snippets(), ["sig=mine"], "the edit comes back to the Mac that deleted it")
    }

    func testDeletedHereAndEditedThereIsAskedAbout() async throws {
        let a = try makeMac()
        let b = try makeMac()
        try a.addSnippet("sig", "Best")
        try await a.sync()
        advance()
        try await b.sync()
        advance()
        try a.removeSnippet("sig")
        advance()
        try b.editSnippet("sig", expansion: "from B")
        try await b.sync()
        advance(3600)

        let plan = try await a.plan()
        XCTAssertEqual(plan.conflicts.map(\.title), ["sig"])
        XCTAssertNil(plan.conflicts.first?.thisMac, "deleted on this Mac")
        XCTAssertEqual(plan.conflicts.first?.otherMac, "from B")

        try await a.engine.commit(answer: DictionarySyncAnswer(conflicts: .otherMac), reviewed: plan.reviewedKeys)
        XCTAssertEqual(try a.snippets(), ["sig=from B"], "the other Mac's edit wins over this deletion")
    }

    func testDeletedHereStaysDeletedWhenThisMacIsChosen() async throws {
        let a = try makeMac()
        let b = try makeMac()
        try a.addSnippet("sig", "Best")
        try await a.sync()
        advance()
        try await b.sync()
        advance()
        try a.removeSnippet("sig")
        try b.editSnippet("sig", expansion: "from B")
        advance()
        try await b.sync()
        advance(3600)

        try await a.sync(.remove, conflicts: .thisMac)
        XCTAssertEqual(try a.snippets(), [])
        XCTAssertEqual(try fileArchive().snippets?.count, 0)
    }

    func testAChangeOnOneSideOnlyAppliesWithoutAsking() async throws {
        let a = try makeMac()
        let b = try makeMac()
        try a.addSnippet("one", "1")
        try a.addSnippet("two", "2")
        try await a.sync()
        advance()
        try await b.sync()
        advance()

        // Only A changes "one"; only B changes "two".
        try a.editSnippet("one", expansion: "1 from A")
        try b.editSnippet("two", expansion: "2 from B")
        advance(3600)
        try await b.sync()
        advance(3600)
        let plan = try await a.plan()
        XCTAssertEqual(plan.conflicts, [], "A's edit and B's edit are different entries")
        XCTAssertEqual(plan.removals, [])
        try await a.sync()
        XCTAssertEqual(try a.snippets(), ["one=1 from A", "two=2 from B"])
        advance()
        let back = try await b.plan()
        XCTAssertEqual(back.conflicts, [])
        try await b.sync()
        XCTAssertEqual(try b.snippets(), ["one=1 from A", "two=2 from B"])
    }

    func testTwoSnippetsWithOneTriggerOnFirstMergeAskWhichTextStays() async throws {
        let a = try makeMac()
        let b = try makeMac()
        try a.addSnippet("my email", "old@example.com")
        try await a.sync()
        advance()
        try b.addSnippet("My Email", "new@example.com")

        let plan = try await b.plan()
        XCTAssertEqual(plan.conflicts.count, 1)
        XCTAssertEqual(plan.conflicts.first?.thisMac, "new@example.com")
        XCTAssertEqual(plan.conflicts.first?.otherMac, "old@example.com")
        try await b.engine.commit(answer: DictionarySyncAnswer(conflicts: .otherMac), reviewed: plan.reviewedKeys)
        XCTAssertEqual(try b.snippets().map { $0.lowercased() }, ["my email=old@example.com"])
        XCTAssertEqual(try fileArchive().snippets?.count, 1)
    }

    // MARK: Removals that are not folded into another entry

    func testRuleDeletedElsewhereIsListedEvenWhenAnotherRuleHasTheSameText() async throws {
        let a = try makeMac()
        let b = try makeMac()
        try a.addReplacement("teh", to: "the")
        try await a.sync()
        advance()
        try await b.sync()
        advance()
        try b.removeReplacement(to: "the")
        advance()
        try b.addReplacement("thx", to: "the")
        try await b.sync()
        advance()

        let plan = try await a.plan()
        XCTAssertEqual(plan.removals.map(\.title), ["teh → the"], "its source is not in the other rule")
        XCTAssertEqual(try a.replacements(), ["teh → the"])

        let kept = try await a.engine.commit(answer: .init(removals: .keep), reviewed: plan.reviewedKeys)
        XCTAssertEqual(kept.removed, 0)
        XCTAssertEqual(try a.replacements(), ["thx, teh → the"], "kept: the sources are joined into one rule")
    }

    func testRuleFoldedIntoAnotherIsNotARemoval() async throws {
        let a = try makeMac()
        let b = try makeMac()
        try a.addReplacement("teh", to: "the")
        try b.addReplacement("teh", to: "the")
        try b.addReplacement("adn", to: "and")
        try await a.sync()
        advance()
        let plan = try await b.plan()
        XCTAssertEqual(plan.removals, [], "the same source for the same text becomes one rule")
        try await b.sync()
        XCTAssertEqual(try b.replacements(), ["adn → and", "teh → the"])
    }

    // MARK: Rules that are switched off

    func testSwitchedOffRuleSyncsAndOldFilesReadAsOn() async throws {
        let a = try makeMac()
        let b = try makeMac()
        try a.addReplacement("teh", to: "the")
        try await a.sync()
        advance()
        try await b.sync()
        XCTAssertEqual(try b.replacementStates(), ["the": true])

        advance()
        try a.setReplacementEnabled(to: "the", false)
        try await a.sync()
        advance()
        try await b.sync()
        XCTAssertEqual(try b.replacementStates(), ["the": false])
        XCTAssertEqual(try fileArchive().replacements.first?.isEnabled, false)

        let old = DictionaryArchive(
            vocabulary: [],
            replacements: [DictionaryReplacementEntry(sources: ["teh"], replacement: "the", createdAt: Date())])
        let state = DictionarySyncFormat.state(from: old, now: Date())
        guard case .replacement(_, _, let isEnabled)? = state.records.values.first?.payload else {
            return XCTFail("a rule")
        }
        XCTAssertTrue(isEnabled, "a file without the key means on")
    }

    // MARK: First merge, lifetime, clock, store identity

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
        XCTAssertEqual(
            try a.replacementIDs().sorted { $0.uuidString < $1.uuidString },
            try b.replacementIDs().sorted { $0.uuidString < $1.uuidString })
    }

    func testMissingStateWithRemoteTombstonesNeverDeletesLocalEntries() async throws {
        let a = try makeMac()
        let b = try makeMac()
        try a.addWord("Pnoe")
        try a.addWord("Precious")
        try await a.sync()
        advance()
        try await b.sync()
        advance()
        try b.removeWord("Precious")
        try await b.sync()
        advance()
        XCTAssertEqual(try fileState().tombstones.count, 1)

        // A new Mac (or this one with its state file lost) has "Precious" and has never synced.
        let fresh = try makeMac()
        try fresh.addWord("Precious")
        try fresh.addWord("Mine")
        let plan = try await fresh.plan()
        XCTAssertEqual(plan.removals, [], "a first merge removes nothing")
        try await fresh.sync()
        XCTAssertEqual(try fresh.words(), ["Mine", "Pnoe", "Precious"])
        XCTAssertEqual(try fileState().tombstones.count, 0, "the kept entry is in the file again")
    }

    func testResetStoreWithStaleStateIsAFirstMergeAndWipesNobody() async throws {
        let stateURL = directory.appendingPathComponent("state-shared.json")
        let a = try makeMac(stateFile: stateURL)
        let b = try makeMac()
        try a.addWord("Pnoe")
        try a.addSnippet("sig", "Best")
        try await a.sync()
        advance()
        try await b.sync()

        // A's store is reset: an empty store, the old state file, a new store token.
        let reset = try makeMac(stateFile: stateURL)
        advance()
        let report = try await reset.sync()
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(try reset.words(), ["Pnoe"], "the entries come back from the file")
        XCTAssertEqual(try reset.snippets(), ["sig=Best"])
        XCTAssertEqual(try fileState().tombstones.count, 0, "the reset Mac wrote no deletions")
        advance()
        try await b.sync()
        XCTAssertEqual(try b.words(), ["Pnoe"])
    }

    func testStateOfAnotherStoreIsNotTrustedEvenWhenTheFileSurvives() async throws {
        let token = SyncTestToken()
        let stateURL = directory.appendingPathComponent("state-token.json")
        let a = try makeMac(stateFile: stateURL, token: token)
        try a.addWord("Pnoe")
        try await a.sync()
        advance()

        // The store was swapped for an empty one: the token changes, the state file stays.
        let swapped = try makeMac(stateFile: stateURL, token: token)
        token.reset()
        let plan = try await swapped.plan()
        XCTAssertEqual(plan.removals, [])
        XCTAssertEqual(plan.added, 1)
    }

    func testStoreIdentityChangesWhenTheStoreFileIsMadeAgain() throws {
        let store = directory.appendingPathComponent("dictionary.store")
        let tokenFile = directory.appendingPathComponent("store-id.json")
        try Data("one".utf8).write(to: store)
        let first = DictionaryStoreIdentity.token(storeURL: store, tokenURL: tokenFile)
        XCTAssertEqual(DictionaryStoreIdentity.token(storeURL: store, tokenURL: tokenFile), first)

        try FileManager.default.removeItem(at: store)
        try Data("two".utf8).write(to: store)
        let second = DictionaryStoreIdentity.token(storeURL: store, tokenURL: tokenFile)
        XCTAssertNotEqual(second, first, "a store deleted and made again is another store")

        try FileManager.default.removeItem(at: tokenFile)
        XCTAssertNotEqual(DictionaryStoreIdentity.token(storeURL: store, tokenURL: tokenFile), second)
    }

    func testMacAwayLongerThanTheLifetimeDoesNotBringDeletedEntriesBack() async throws {
        let (a, _) = try await macAwayForOneHundredTenDays()
        let plan = try await a.plan()
        XCTAssertEqual(plan.removals.map(\.title), ["x"], "unchanged since the last pass and gone from the file")
        XCTAssertEqual(plan.removals.map(\.reason), [.notInFile], "not a deletion by another Mac")
        let report = try await a.engine.commit(answer: .init(removals: .remove), reviewed: plan.reviewedKeys)
        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(try a.snippets(), ["y=edited meanwhile"], "only the entry edited since goes up")
        XCTAssertEqual(try fileState().records.count, 1)
        XCTAssertNil(try fileArchive().snippets?.first { $0.trigger == "x" })
    }

    func testKeepingAfterTheLifetimeUploadsTheEntriesAgain() async throws {
        let (a, _) = try await macAwayForOneHundredTenDays()
        let plan = try await a.plan()
        try await a.engine.commit(answer: .init(removals: .keep), reviewed: plan.reviewedKeys)
        XCTAssertEqual(try a.snippets(), ["x=1", "y=edited meanwhile"])
        XCTAssertEqual(try fileArchive().snippets?.count, 2)
    }

    /// A syncs, B deletes `x` and syncs, the deletion expires from the file, 110 days pass, A edited `y`.
    private func macAwayForOneHundredTenDays() async throws -> (SyncTestMac, SyncTestMac) {
        let a = try makeMac()
        let b = try makeMac()
        try a.addSnippet("x", "1")
        try a.addSnippet("y", "1")
        try await a.sync()
        advance()
        try await b.sync()
        advance(10 * day)
        try b.removeSnippet("x")
        try await b.sync()
        advance(100 * day)
        try await b.sync()
        XCTAssertEqual(try fileState().tombstones.count, 0, "the deletion expired from the file")
        try a.editSnippet("y", expansion: "edited meanwhile")
        return (a, b)
    }

    func testTombstonesLastNinetyDays() {
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

    func testDatesFromAWrongClockAreClampedAndTheFileIsFixed() async throws {
        let a = try makeMac()
        try a.addWord("Pnoe")
        try await a.sync()
        advance()

        // Another Mac with a clock a year ahead deleted "Pnoe" and added "Future".
        let year = 365 * day
        var state = try fileState()
        state.records[.vocabulary(term: "Pnoe")] = nil
        state.tombstones[.vocabulary(term: "Pnoe")] = clock.now.addingTimeInterval(year)
        state.records[.vocabulary(term: "Future")] = wordRecord("Future", at: clock.now.addingTimeInterval(year))
        try write(state)

        let decoded = try DictionarySyncFormat.decode(Data(contentsOf: syncFile), now: clock.now)
        XCTAssertTrue(decoded.hadFutureDates)
        XCTAssertEqual(decoded.state.tombstones[.vocabulary(term: "Pnoe")], clock.now)
        XCTAssertEqual(decoded.state.records[.vocabulary(term: "Future")]?.modifiedAt, clock.now)

        // The deletion still counts (as of now) and is shown; the file is written with real dates.
        let plan = try await a.plan()
        XCTAssertEqual(plan.removals.map(\.title), ["Pnoe"])
        try await a.sync()
        XCTAssertEqual(try fileState().tombstones[.vocabulary(term: "Pnoe")], clock.now)

        // A later edit beats that deletion; a far-future one would have beaten it for good.
        advance()
        try a.addWord("Pnoe")
        try await a.sync()
        advance()
        try await a.sync()
        XCTAssertEqual(try a.words(), ["Future", "Pnoe"])
        XCTAssertNotNil(try fileState().records[.vocabulary(term: "Pnoe")])
    }

    // MARK: Files that can't be used

    func testMalformedFileIsNeverOverwritten() async throws {
        let a = try makeMac()
        try a.addWord("Pnoe")
        let garbage = Data("{ this is not json".utf8)
        try garbage.write(to: syncFile)

        for step in 0..<2 {
            do {
                if step == 0 { _ = try await a.plan() } else { try await a.sync() }
                XCTFail("an unreadable file must stop the pass")
            } catch {
                XCTAssertEqual(error as? DictionarySyncError, .unreadableFile)
            }
        }
        XCTAssertEqual(try Data(contentsOf: syncFile), garbage)
        XCTAssertEqual(try a.words(), ["Pnoe"], "the local dictionary is untouched")
    }

    func testFileOfAnotherFormatOrNewerVersionIsLeftAlone() async throws {
        let a = try makeMac()
        try a.addWord("Pnoe")
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

    func testRecordsThisVersionCannotUseStayInTheFileAndOutOfTheStore() async throws {
        let a = try makeMac()
        try a.addWord("Pnoe")
        try await a.sync()
        advance()
        var state = try fileState()
        let odd = DictionarySyncRecord(
            key: DictionarySyncKey(kind: .snippet, id: UUID().uuidString),
            payload: .snippet(trigger: "!!!", expansion: "no letters in the trigger"),
            createdAt: clock.now, modifiedAt: clock.now)
        state.records[odd.key] = odd
        try write(state)

        // A pass that writes (A has a new word) must not drop what it can't use.
        advance()
        try a.addWord("Extra")
        let report = try await a.sync()
        XCTAssertTrue(report.wroteFile)
        XCTAssertEqual(try a.snippets(), [], "the store does not take it")
        XCTAssertEqual(try fileArchive().snippets?.count, 1, "the file keeps it")
        XCTAssertEqual(try fileArchive().vocabulary.map(\.term).sorted(), ["Extra", "Pnoe"])
    }

    func testFileStillInICloudIsAskedForAndNothingIsTouched() async throws {
        let b = try makeMac()
        try b.addWord("FromB")
        try await b.sync()

        // iCloud keeps a stub named `.<file>.icloud` until the file is downloaded.
        let stub = folder.appendingPathComponent(".\(syncFile.lastPathComponent).icloud")
        let held = directory.appendingPathComponent("held.json")
        try FileManager.default.moveItem(at: syncFile, to: held)
        try Data("stub".utf8).write(to: stub)

        let a = try makeMac()
        try a.addWord("FromA")
        for step in 0..<2 {
            do {
                if step == 0 { _ = try await a.plan() } else { try await a.sync() }
                XCTFail("a file that is not on this Mac yet must not be merged or replaced")
            } catch {
                XCTAssertEqual(error as? DictionarySyncError, .notDownloaded)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: syncFile.path))
        XCTAssertEqual(try a.words(), ["FromA"])

        try FileManager.default.removeItem(at: stub)
        try FileManager.default.moveItem(at: held, to: syncFile)
        advance()
        try await a.sync()
        XCTAssertEqual(try a.words(), ["FromA", "FromB"])
    }

    func testMissingFolderIsReportedAndNeverCreated() async throws {
        let gone = directory.appendingPathComponent("no-icloud/Pnoe", isDirectory: true)
        let offline = try makeMac(drive: SyncFileDrive(fileURL: gone.appendingPathComponent("Dictionary Sync.json")))
        try offline.addWord("Pnoe")
        for step in 0..<2 {
            do {
                if step == 0 { _ = try await offline.plan() } else { try await offline.sync() }
                XCTFail("no folder means no pass")
            } catch {
                XCTAssertEqual(error as? DictionarySyncError, .folderMissing)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.deletingLastPathComponent().path))
        XCTAssertEqual(try offline.words(), ["Pnoe"])
    }

    func testCancelledPassWritesNothing() async throws {
        let a = try makeMac()
        try a.addWord("Pnoe")
        let cancellation = DictionarySyncCancellation()
        cancellation.cancel()
        do {
            _ = try await a.engine.commit(answer: .init(removals: .remove), reviewed: [], cancellation: cancellation)
            XCTFail("a cancelled pass must stop")
        } catch {
            XCTAssertEqual(error as? DictionarySyncError, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: syncFile.path))
    }

    // MARK: Conflict copies

    func testConflictVersionsAreMergedThenResolved() async throws {
        let versions = FakeConflictVersions()
        let a = try makeMac(drive: SyncFileDrive(fileURL: syncFile, conflictVersions: versions))
        try a.addWord("Local")
        try await a.sync()
        advance()

        var other = DictionarySyncState()
        other.records[.vocabulary(term: "FromConflict")] = wordRecord("FromConflict", at: clock.now)
        let good = FakeConflictVersions.Version(
            try DictionarySyncFormat.encode(other, deviceID: "other-mac", now: clock.now))
        let bad = FakeConflictVersions.Version(Data("not a dictionary".utf8))
        versions.versions = [good, bad]

        advance()
        try await a.sync()
        XCTAssertEqual(try a.words(), ["FromConflict", "Local"])
        XCTAssertNotNil(try fileState().records[.vocabulary(term: "FromConflict")])
        XCTAssertTrue(good.isResolved, "the merged copy is resolved")
        XCTAssertFalse(bad.isResolved, "a copy that can't be read is left alone")
    }

    func testSiblingCopyIsMergedThenRemovedAndOthersStay() async throws {
        let a = try makeMac()
        try a.addWord("Local")
        try await a.sync()
        advance()

        var other = DictionarySyncState()
        other.records[.vocabulary(term: "FromSibling")] = wordRecord("FromSibling", at: clock.now)
        let sibling = folder.appendingPathComponent("Dictionary Sync 2.json")
        try DictionarySyncFormat.encode(other, deviceID: "other-mac", now: clock.now).write(to: sibling)
        let unrelated = folder.appendingPathComponent("Notes.json")
        try Data("{}".utf8).write(to: unrelated)
        let broken = folder.appendingPathComponent("Dictionary Sync 3.json")
        try Data("broken".utf8).write(to: broken)

        advance()
        try await a.sync()
        XCTAssertEqual(try a.words(), ["FromSibling", "Local"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sibling.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: broken.path), "a copy that can't be read stays")
    }

    // MARK: Format

    func testSyncFileStaysReadableByTheManualImport() async throws {
        let a = try makeMac()
        try a.addWord("Pnoe")
        try a.addReplacement("teh, adn", to: "the")
        try await a.sync()

        let archive = try fileArchive()
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
        let now = Date()
        let first = DictionarySyncFormat.state(from: archive, now: now)
        let second = DictionarySyncFormat.state(from: archive, now: now)
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

// MARK: - The Sync now button

@MainActor
final class DictionarySyncControllerTests: XCTestCase {
    private var directory: URL!
    private var folder: URL!
    private var syncFile: URL!
    private var clock: SyncTestClock!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pnoe-sync-controller-\(UUID().uuidString)", isDirectory: true)
        folder = directory.appendingPathComponent("Pnoe", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        syncFile = folder.appendingPathComponent("Dictionary Sync.json")
        clock = SyncTestClock()
        suite = "DictionarySyncControllerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    /// A controller wired to a fake Mac's store, with every path in the temp folder.
    private func makeController(mac: SyncTestMac, stateName: String = "state.json") -> DictionarySyncController {
        let controller = DictionarySyncController(
            defaults: defaults, stateFileURL: directory.appendingPathComponent(stateName),
            clock: { [clock] in clock!.now })
        let container = mac.container
        let token = mac.token
        let clock = self.clock!
        controller.engineFactory = { file, stateFile in
            DictionarySyncEngine(
                store: DictionarySyncStore(modelContainer: container), drive: SyncFileDrive(fileURL: file),
                stateFile: stateFile, storeIdentity: { token.current }, clock: { clock.now })
        }
        return controller
    }

    private func makeMac(_ name: String) throws -> SyncTestMac {
        try SyncTestMac(
            drive: SyncFileDrive(fileURL: syncFile), stateFile: directory.appendingPathComponent(name), clock: clock)
    }

    /// Waits until the controller shows a review (the pass then waits for the answer).
    private func waitForReview(_ controller: DictionarySyncController) async throws {
        for _ in 0..<500 {
            if controller.review != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("the pass never asked about the removals")
        controller.answerReview(nil)
    }

    func testNothingRunsUntilTheButtonIsClicked() async throws {
        let mac = try makeMac("mac.json")
        try mac.addWord("Pnoe")
        let controller = makeController(mac: mac)
        controller.useSyncFile(syncFile)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: syncFile.path), "choosing a file syncs nothing")
        XCTAssertNil(controller.result)
        XCTAssertTrue(controller.canSync)

        await controller.syncNow()
        XCTAssertTrue(FileManager.default.fileExists(atPath: syncFile.path))
        XCTAssertEqual(controller.result?.kind, .success(added: 0, updated: 0, removed: 0))
        XCTAssertFalse(controller.isWorking)
    }

    func testTheChosenFileIsRememberedAndNoFileMeansNoSync() async throws {
        let mac = try makeMac("mac.json")
        let controller = makeController(mac: mac)
        XCTAssertNil(controller.syncFile)
        XCTAssertFalse(controller.canSync)

        controller.useSyncFile(syncFile)
        XCTAssertEqual(controller.syncFile?.name, "Dictionary Sync.json")

        let again = makeController(mac: mac)
        XCTAssertEqual(again.syncFile?.name, "Dictionary Sync.json", "remembered across launches")
        XCTAssertEqual(again.syncFileURL?.standardizedFileURL.path, syncFile.standardizedFileURL.path)
    }

    func testResultLineSurvivesALaunchAndAnotherFileStartsOver() async throws {
        let mac = try makeMac("mac.json")
        try mac.addWord("Pnoe")
        let controller = makeController(mac: mac)
        controller.useSyncFile(syncFile)
        await controller.syncNow()
        XCTAssertEqual(makeController(mac: mac).result?.kind, .success(added: 0, updated: 0, removed: 0))

        controller.useSyncFile(folder.appendingPathComponent("Other.json"))
        XCTAssertNil(controller.result)
        XCTAssertNil(makeController(mac: mac).result)
    }

    func testReviewKeepAndRemove() async throws {
        let a = try makeMac("a.json")
        let b = try makeMac("b.json")
        // Choosing the file starts a new history, so it comes first.
        let controller = makeController(mac: a, stateName: "a.json")
        controller.useSyncFile(syncFile)
        try a.addWord("Pnoe")
        try a.addWord("Gone")
        try await a.sync()
        clock.advance(10)
        try await b.sync()
        clock.advance(10)
        try b.removeWord("Gone")
        try await b.sync()
        clock.advance(10)

        let task = Task { await controller.syncNow() }
        try await waitForReview(controller)
        XCTAssertEqual(controller.review?.removals.map(\.title), ["Gone"])
        XCTAssertEqual(controller.review?.deletedElsewhere.count, 1)
        XCTAssertEqual(controller.review?.conflicts, [])
        XCTAssertEqual(try a.words(), ["Gone", "Pnoe"], "nothing changes while the question is open")
        controller.answerReview(DictionarySyncAnswer(removals: .keep))
        await task.value
        XCTAssertEqual(try a.words(), ["Gone", "Pnoe"])
        XCTAssertEqual(controller.result?.kind, .success(added: 0, updated: 0, removed: 0))

        // Delete it on B again, and this time remove.
        clock.advance(10)
        try await b.sync()
        clock.advance(10)
        try b.removeWord("Gone")
        try await b.sync()
        clock.advance(10)
        let second = Task { await controller.syncNow() }
        try await waitForReview(controller)
        controller.answerReview(DictionarySyncAnswer(removals: .remove))
        await second.value
        XCTAssertEqual(try a.words(), ["Pnoe"])
        XCTAssertEqual(controller.result?.kind, .success(added: 0, updated: 0, removed: 1))
    }

    func testCancelDuringTheReviewChangesNothing() async throws {
        let a = try makeMac("a.json")
        let b = try makeMac("b.json")
        let controller = makeController(mac: a, stateName: "a.json")
        controller.useSyncFile(syncFile)
        try a.addWord("Gone")
        try await a.sync()
        clock.advance(10)
        try await b.sync()
        clock.advance(10)
        try b.removeWord("Gone")
        try await b.sync()
        clock.advance(10)
        let before = try Data(contentsOf: syncFile)

        let task = Task { await controller.syncNow() }
        try await waitForReview(controller)
        XCTAssertTrue(controller.isWorking, "the button is off while a pass runs")
        XCTAssertFalse(controller.canSync)
        controller.cancel()
        await task.value
        XCTAssertEqual(controller.result?.kind, .cancelled)
        XCTAssertEqual(try a.words(), ["Gone"])
        XCTAssertEqual(try Data(contentsOf: syncFile), before)
    }

    func testClosingTheQuestionWithoutAnsweringStopsThePassAndWritesNothing() async throws {
        let a = try makeMac("a.json")
        let b = try makeMac("b.json")
        let controller = makeController(mac: a, stateName: "a.json")
        controller.useSyncFile(syncFile)
        try a.addSnippet("sig", "Best")
        try await a.sync()
        clock.advance(10)
        try await b.sync()
        clock.advance(10)
        try a.editSnippet("sig", expansion: "from A")
        try b.editSnippet("sig", expansion: "from B")
        try await b.sync()
        clock.advance(3600)
        let before = try Data(contentsOf: syncFile)

        let task = Task { await controller.syncNow() }
        try await waitForReview(controller)
        XCTAssertEqual(controller.review?.conflicts.map(\.title), ["sig"])
        controller.answerReview(nil)  // the sheet was dismissed
        await task.value
        XCTAssertEqual(controller.result?.kind, .cancelled)
        XCTAssertEqual(try a.snippets(), ["sig=from A"])
        XCTAssertEqual(try Data(contentsOf: syncFile), before)
    }

    func testProblemsAreShownWithTheirReason() async throws {
        let mac = try makeMac("mac.json")
        try mac.addWord("Pnoe")
        let controller = makeController(mac: mac)

        // The folder is gone.
        controller.useSyncFile(directory.appendingPathComponent("gone/Dictionary Sync.json"))
        await controller.syncNow()
        XCTAssertEqual(
            controller.result?.kind, .failure(DictionarySyncController.message(for: .folderMissing)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("gone").path))

        // The file can't be read.
        controller.useSyncFile(syncFile)
        let garbage = Data("not json".utf8)
        try garbage.write(to: syncFile)
        await controller.syncNow()
        XCTAssertEqual(
            controller.result?.kind, .failure(DictionarySyncController.message(for: .unreadableFile)))
        XCTAssertEqual(try Data(contentsOf: syncFile), garbage)
        XCTAssertEqual(try mac.words(), ["Pnoe"])
    }

    func testWithoutAStoreThereIsNothingToSync() async throws {
        let controller = DictionarySyncController(
            defaults: defaults, stateFileURL: directory.appendingPathComponent("s.json"))
        controller.useSyncFile(syncFile)
        XCTAssertFalse(controller.canSync)
        await controller.syncNow()
        if case .failure = controller.result?.kind {} else { XCTFail("a message is shown") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: syncFile.path))
    }
}

// MARK: - Export and import locations

final class DictionaryTransferTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        return calendar
    }()
    private var exportDate: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 14, minute: 5))!
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pnoe-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "DictionaryTransferTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    func testExportFolderIsRememberedAndExportNeedsNoDialog() throws {
        let location = RememberedLocation(defaults: defaults, key: DictionaryLocationKeys.exportFolder)
        XCTAssertNil(location.resolve())

        let folder = directory.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        location.remember(folder)

        let again = RememberedLocation(defaults: defaults, key: DictionaryLocationKeys.exportFolder)
        let remembered = try XCTUnwrap(again.resolve())
        let url = try DictionaryTransfer.export(
            Data("{}".utf8), toFolder: remembered, at: exportDate, calendar: calendar)
        XCTAssertEqual(url.lastPathComponent, "Pnoe Dictionary 2026-10-20 14.05.json")
        XCTAssertEqual(try Data(contentsOf: url), Data("{}".utf8))

        // The same minute again, and a later one: nothing is replaced.
        let second = try DictionaryTransfer.export(
            Data("[]".utf8), toFolder: remembered, at: exportDate, calendar: calendar)
        XCTAssertEqual(second.lastPathComponent, "Pnoe Dictionary 2026-10-20 14.05 2.json")
        let later = try DictionaryTransfer.export(
            Data("[1]".utf8), toFolder: remembered, at: exportDate.addingTimeInterval(120), calendar: calendar)
        XCTAssertEqual(later.lastPathComponent, "Pnoe Dictionary 2026-10-20 14.07.json")
        XCTAssertEqual(try Data(contentsOf: url), Data("{}".utf8), "the first export is untouched")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 3)
    }

    func testRememberedFolderFollowsARenameAndAMissingFolderIsReported() throws {
        let location = RememberedLocation(defaults: defaults, key: DictionaryLocationKeys.exportFolder)
        let folder = directory.appendingPathComponent("Before", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        location.remember(folder)

        let renamed = directory.appendingPathComponent("After", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: renamed)
        XCTAssertEqual(location.resolve()?.lastPathComponent, "After")

        try FileManager.default.removeItem(at: renamed)
        let gone = try XCTUnwrap(location.resolve())
        XCTAssertThrowsError(try DictionaryTransfer.export(Data(), toFolder: gone)) {
            guard case DictionaryTransfer.Failure.folderMissing = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path), "an export never creates the folder")
    }

    func testImportFileIsRememberedAndAMissingFileIsReported() throws {
        let location = RememberedLocation(defaults: defaults, key: DictionaryLocationKeys.importFile)
        let file = directory.appendingPathComponent("Dictionary.json")
        try Data("one".utf8).write(to: file)
        location.remember(file)

        let remembered = try XCTUnwrap(
            RememberedLocation(defaults: defaults, key: DictionaryLocationKeys.importFile).resolve())
        XCTAssertEqual(try DictionaryTransfer.importData(from: remembered), Data("one".utf8))

        try FileManager.default.removeItem(at: file)
        let gone = try XCTUnwrap(location.resolve())
        XCTAssertThrowsError(try DictionaryTransfer.importData(from: gone)) {
            guard case DictionaryTransfer.Failure.fileMissing = $0 else { return XCTFail("\($0)") }
        }
    }

    func testSyncFileIsDescribedWithItsFolder() {
        let root = directory.appendingPathComponent("CloudDocs", isDirectory: true)
        let inPnoe = root.appendingPathComponent("Pnoe/Dictionary Sync.json")
        XCTAssertEqual(
            DictionarySyncFileDescription.describing(inPnoe, iCloudRoot: root, home: directory),
            DictionarySyncFileDescription(name: "Dictionary Sync.json", folder: "iCloud Drive/Pnoe"))
        XCTAssertEqual(
            DictionarySyncFileDescription.describing(
                root.appendingPathComponent("Dictionary Sync.json"), iCloudRoot: root, home: directory
            ).folder, "iCloud Drive")
        XCTAssertEqual(
            DictionarySyncFileDescription.describing(
                directory.appendingPathComponent("Documents/Sync.json"), iCloudRoot: root, home: directory
            ).folder, "~/Documents")
    }

    func testPanelSuggestionNeverCreatesFolders() throws {
        let root = directory.appendingPathComponent("CloudDocs", isDirectory: true)
        XCTAssertNil(DictionarySyncFileDescription.suggestedDirectory(iCloudRoot: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(DictionarySyncFileDescription.suggestedDirectory(iCloudRoot: root)?.path, root.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Pnoe").path))

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Pnoe"), withIntermediateDirectories: true)
        XCTAssertEqual(
            DictionarySyncFileDescription.suggestedDirectory(iCloudRoot: root)?.lastPathComponent, "Pnoe")
    }
}
