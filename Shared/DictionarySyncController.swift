import Foundation
import OSLog
import SwiftData

/// How the last sync went, as the settings row shows it.
struct DictionarySyncResultLine: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case success(added: Int, updated: Int, removed: Int)
        case cancelled
        case failure(String)
    }

    var kind: Kind
    var at: Date
}

/// The question before a pass changes anything the user may care about: entries it would remove, and
/// entries that changed on both Macs. It waits for the user's answer.
struct DictionarySyncReview: Identifiable, Equatable, Sendable {
    let id = UUID()
    let removals: [DictionarySyncRemoval]
    let conflicts: [DictionarySyncConflict]

    /// How many names a list shows before "and N more".
    static let sampleSize = 5

    var deletedElsewhere: [DictionarySyncRemoval] { removals.filter { $0.reason == .deletedElsewhere } }
    var notInFile: [DictionarySyncRemoval] { removals.filter { $0.reason == .notInFile } }
}

/// The dictionary sync file and its "Sync now" button. Nothing here runs by itself: no watcher, no timer,
/// no pass at launch. A pass runs when the user clicks Sync now, and only on the file the user chose.
@MainActor
final class DictionarySyncController: ObservableObject {
    static let shared = DictionarySyncController()

    static let lastResultKey = "dictionarySyncLastResult"

    /// Whether this build shows the sync file. The dictionary store of a signed release build syncs
    /// through CloudKit (issue #5), which this file stands in for until a paid Apple Developer membership
    /// makes that build possible. There the section is hidden. Builds where CloudKit is off (Debug,
    /// `make local`) show it. When #5 lands, remove this sync and move its data into CloudKit.
    static var isAvailable: Bool {
        #if DEBUG || LOCAL_BUILD
            true
        #else
            false
        #endif
    }

    @Published private(set) var syncFile: DictionarySyncFileDescription?
    @Published private(set) var isWorking = false
    @Published private(set) var result: DictionarySyncResultLine?
    /// Set while a pass waits for the user to choose what to do with entries it would remove.
    @Published private(set) var review: DictionarySyncReview?
    /// The symbol phase: pulses while a pass runs, shows a check after one finished.
    @Published private(set) var symbolPhase: MotionPhase = .idle

    /// Builds the engine for a sync file; `nil` when there is no store to sync (the app fell back to
    /// in-memory storage, or `configure` was not called).
    var engineFactory: ((URL, DictionarySyncLocalStateFile) -> DictionarySyncEngine?)?

    private static let logger = Logger(subsystem: "com.techneissa.pnoe", category: "DictionarySync")

    private let defaults: UserDefaults
    private let location: RememberedLocation
    private let stateFile: DictionarySyncLocalStateFile
    private let clock: @Sendable () -> Date
    private var cancellation = DictionarySyncCancellation()
    private var reviewContinuation: CheckedContinuation<DictionarySyncAnswer?, Never>?
    private var checkHold: Task<Void, Never>?
    private var passTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        stateFileURL: URL = DictionarySyncController.defaultStateFileURL,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.stateFile = DictionarySyncLocalStateFile(url: stateFileURL)
        self.location = RememberedLocation(defaults: defaults, key: DictionaryLocationKeys.syncFile)
        self.clock = clock
        syncFile = location.resolve().map { DictionarySyncFileDescription.describing($0) }
        result = Self.loadResult(defaults)
    }

    nonisolated static var defaultStateFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.techneissa.Pnoe", isDirectory: true)
            .appendingPathComponent("dictionary-sync-state.json")
    }

    /// Called once at launch with the app's persistent store. It only remembers the store; it starts nothing.
    func configure(container: ModelContainer, storeURL: URL, identityURL: URL) {
        let clock = self.clock
        engineFactory = { file, stateFile in
            DictionarySyncEngine(
                store: DictionarySyncStore(modelContainer: container),
                drive: SyncFileDrive(fileURL: file),
                stateFile: stateFile,
                storeIdentity: { DictionaryStoreIdentity.token(storeURL: storeURL, tokenURL: identityURL) },
                clock: clock)
        }
    }

    var canSync: Bool { syncFile != nil && !isWorking && engineFactory != nil }

    /// The remembered file, or `nil` when none was chosen.
    var syncFileURL: URL? { location.resolve() }

    // MARK: Choosing the file

    /// Remembers the file the user picked. A different file starts a new history: what this Mac remembered
    /// about the old one is dropped, so the first pass on the new one merges and deletes nothing.
    func useSyncFile(_ url: URL) {
        if location.resolve()?.standardizedFileURL != url.standardizedFileURL {
            stateFile.remove()
            result = nil
            defaults.removeObject(forKey: Self.lastResultKey)
        }
        location.remember(url)
        syncFile = DictionarySyncFileDescription.describing(url)
    }

    // MARK: Sync now

    /// Starts a pass for a click; the buttons follow `isWorking`.
    func syncNowTapped() {
        guard passTask == nil else { return }
        passTask = Task { [weak self] in
            await self?.syncNow()
            self?.passTask = nil
        }
    }

    func syncNow() async {
        guard !isWorking, let file = location.resolve() else { return }
        guard let engine = engineFactory?(file, stateFile) else {
            finish(.failure(String(localized: "The dictionary can't be synced while it is kept in memory only.")))
            return
        }
        isWorking = true
        cancellation = DictionarySyncCancellation()
        checkHold?.cancel()
        symbolPhase = .running
        review = nil

        var outcome: Outcome = .retry
        var attempts = 0
        while case .retry = outcome, attempts < 3 {
            attempts += 1
            outcome = await runOnce(engine)
        }
        switch outcome {
        case .done(let kind):
            finish(kind)
        case .retry:
            finish(.failure(String(localized: "The dictionary kept changing during the sync. Try again.")))
        }
    }

    private enum Outcome {
        case done(DictionarySyncResultLine.Kind)
        /// The entries to remove changed after the user was asked; ask again.
        case retry
    }

    /// Plan, ask if anything would be removed, commit.
    private func runOnce(_ engine: DictionarySyncEngine) async -> Outcome {
        do {
            let plan = try await engine.plan(cancellation: cancellation)
            var answer = DictionarySyncAnswer()
            if plan.needsReview {
                review = DictionarySyncReview(removals: plan.removals, conflicts: plan.conflicts)
                let given = await withCheckedContinuation { reviewContinuation = $0 }
                review = nil
                // Closing the question any other way than answering it stops the pass, unchanged.
                guard let given else { return .done(.cancelled) }
                answer = given
            }
            let report = try await engine.commit(
                answer: answer, reviewed: plan.reviewedKeys, cancellation: cancellation)
            return .done(.success(added: report.added, updated: report.updated, removed: report.removed))
        } catch let error as DictionarySyncError {
            switch error {
            case .cancelled: return .done(.cancelled)
            case .changedDuringReview: return .retry
            default:
                Self.logger.notice("Dictionary sync stopped: \(String(describing: error), privacy: .public)")
                return .done(.failure(Self.message(for: error)))
            }
        } catch {
            return .done(.failure(Self.message(for: .failed)))
        }
    }

    /// The user's answer to the review. `nil` (cancel, or closing the question) stops the pass without
    /// writing or applying anything.
    func answerReview(_ answer: DictionarySyncAnswer?) {
        reviewContinuation?.resume(returning: answer)
        reviewContinuation = nil
    }

    /// Stops the pass before it writes.
    func cancel() {
        cancellation.cancel()
        answerReview(nil)
    }

    private func finish(_ kind: DictionarySyncResultLine.Kind) {
        isWorking = false
        let line = DictionarySyncResultLine(kind: kind, at: DictionarySyncMerge.floored(clock()))
        result = line
        switch kind {
        case .success:
            Self.save(line, to: defaults)
            showCheck()
        case .cancelled:
            symbolPhase = .idle
        case .failure:
            symbolPhase = .failed
        }
    }

    /// The check mark stays for about a second, then the symbol goes back (nothing keeps animating).
    private func showCheck() {
        checkHold?.cancel()
        symbolPhase = .finished
        checkHold = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Motion.copiedHold))
            guard !Task.isCancelled, let self else { return }
            self.symbolPhase = .idle
        }
    }

    static func message(for error: DictionarySyncError) -> String {
        switch error {
        case .folderMissing:
            return String(localized: "The folder of the sync file is gone. Choose the file again.")
        case .notDownloaded:
            return String(localized: "The sync file is still downloading from iCloud. Try again in a moment.")
        case .unreadableFile:
            return String(localized: "The sync file can't be read, so it was left as it is.")
        case .writeFailed:
            return String(localized: "The sync file couldn't be written.")
        case .storeFailed:
            return String(localized: "The dictionary couldn't be updated.")
        case .failed, .changedDuringReview:
            return String(localized: "The sync file couldn't be accessed.")
        case .cancelled:
            return String(localized: "Cancelled.")
        }
    }

    // MARK: Last result

    private struct StoredResult: Codable {
        var added: Int
        var updated: Int
        var removed: Int
        var at: Date
    }

    private static func save(_ line: DictionarySyncResultLine, to defaults: UserDefaults) {
        guard case .success(let added, let updated, let removed) = line.kind else { return }
        let stored = StoredResult(added: added, updated: updated, removed: removed, at: line.at)
        defaults.set(try? JSONEncoder().encode(stored), forKey: lastResultKey)
    }

    private static func loadResult(_ defaults: UserDefaults) -> DictionarySyncResultLine? {
        guard let data = defaults.data(forKey: lastResultKey),
            let stored = try? JSONDecoder().decode(StoredResult.self, from: data)
        else { return nil }
        return DictionarySyncResultLine(
            kind: .success(added: stored.added, updated: stored.updated, removed: stored.removed), at: stored.at)
    }
}
