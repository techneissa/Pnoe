import AppKit
import Foundation
import OSLog
import SwiftData

enum DictionarySyncPhase: Equatable, Sendable {
    case off
    case idle
    case syncing
    /// No iCloud Drive folder on this Mac. The switch stays on and Pnoe tries again later.
    case driveOff
    /// The sync file is in iCloud and being downloaded.
    case waitingForDownload
    /// The sync file can't be read; it is left as it is.
    case unreadable
    case failed
}

struct DictionarySyncStatus: Equatable, Sendable {
    var phase: DictionarySyncPhase
    /// The last sync that went through, kept while a later one fails.
    var lastSyncAt: Date?

    var motionPhase: MotionPhase {
        switch phase {
        case .off, .idle: return .idle
        case .syncing: return .running
        case .driveOff, .waitingForDownload, .unreadable, .failed: return .failed
        }
    }
}

/// Runs the opt-in dictionary sync through iCloud Drive and tells the settings row where it is.
///
/// While the switch is off it does nothing: no observer, no file access, no timer. While it is on, a
/// pass runs at launch, on switch-on, when the app becomes active, when the file changes on disk and a
/// few seconds after the dictionary changed. A pass that can't finish is tried again after five minutes.
@MainActor
final class DictionarySyncController: ObservableObject {
    static let shared = DictionarySyncController()

    static let enabledKey = "dictionaryDriveSyncEnabled"
    static let lastSyncKey = "dictionaryDriveSyncLastSync"

    /// Whether this build shows the switch. The dictionary store of a signed release build syncs through
    /// CloudKit (issue #5), which this sync stands in for until a paid Apple Developer membership makes
    /// that build possible. There the switch is hidden and this controller never starts. Builds where
    /// CloudKit is off (Debug, `make local`) show it. When #5 lands, remove this sync and move its data
    /// into CloudKit.
    static var isAvailable: Bool {
        #if DEBUG || LOCAL_BUILD
            true
        #else
            false
        #endif
    }

    static let debounce: Duration = .seconds(3)
    static let retryDelay: Duration = .seconds(300)

    @Published private(set) var isEnabled: Bool
    @Published private(set) var status: DictionarySyncStatus
    /// The symbol phase: pulses while a pass runs, shows a check for a second after one finished.
    @Published private(set) var symbolPhase: MotionPhase = .idle

    private static let logger = Logger(subsystem: "com.techneissa.pnoe", category: "DictionarySync")
    private let defaults: UserDefaults
    private let makeDrive: () -> any DictionarySyncDrive
    private let stateFileURL: URL
    private var container: ModelContainer?
    private var drive: (any DictionarySyncDrive)?
    private var engine: DictionarySyncEngine?
    private var observers: [NSObjectProtocol] = []
    private var scheduled: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var checkHold: Task<Void, Never>?
    private var isRunning = false
    private var runAgain = false

    init(
        defaults: UserDefaults = .standard,
        makeDrive: @escaping () -> any DictionarySyncDrive = { FolderDrive() },
        stateFileURL: URL = DictionarySyncController.defaultStateFileURL
    ) {
        self.defaults = defaults
        self.makeDrive = makeDrive
        self.stateFileURL = stateFileURL
        let enabled = defaults.bool(forKey: Self.enabledKey)
        isEnabled = enabled
        status = DictionarySyncStatus(
            phase: enabled ? .idle : .off,
            lastSyncAt: defaults.object(forKey: Self.lastSyncKey) as? Date)
    }

    nonisolated static var defaultStateFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.techneissa.Pnoe", isDirectory: true)
            .appendingPathComponent("dictionary-sync-state.json")
    }

    /// Called once at launch with the app's store. Starts the sync if the switch was left on.
    func configure(container: ModelContainer) {
        self.container = container
        if isEnabled { start() }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            status.phase = .idle
            start()
        } else {
            stop()
        }
    }

    // MARK: Start and stop

    private func start() {
        guard Self.isAvailable, let container, engine == nil else { return }
        let drive = makeDrive()
        self.drive = drive
        engine = DictionarySyncEngine(
            store: DictionarySyncStore(modelContainer: container),
            drive: drive,
            stateFile: DictionarySyncLocalStateFile(url: stateFileURL))

        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] note in
                let touched = DictionarySyncNotifications.touchesDictionary(note)
                MainActor.assumeIsolated { if touched { self?.requestSync(after: Self.debounce) } }
            })
        observers.append(
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.requestSync(after: .seconds(1)) }
            })
        drive.startWatching { [weak self] in
            Task { @MainActor in self?.requestSync(after: .seconds(2)) }
        }
        requestSync(after: .zero)
    }

    private func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        drive?.stopWatching()
        drive = nil
        engine = nil
        scheduled?.cancel()
        retry?.cancel()
        checkHold?.cancel()
        scheduled = nil
        retry = nil
        checkHold = nil
        runAgain = false
        symbolPhase = .idle
        status.phase = .off
    }

    // MARK: Passes

    private func requestSync(after delay: Duration) {
        guard isEnabled, engine != nil else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.runPass()
        }
    }

    private func runPass() async {
        guard isEnabled, let engine else { return }
        guard !isRunning else {
            runAgain = true
            return
        }
        isRunning = true
        retry?.cancel()
        retry = nil
        status.phase = .syncing
        symbolPhase = .running

        do {
            let report = try await engine.run()
            guard isEnabled else { return finish() }
            defaults.set(report.syncedAt, forKey: Self.lastSyncKey)
            status = DictionarySyncStatus(phase: .idle, lastSyncAt: report.syncedAt)
            showCheck()
        } catch {
            guard isEnabled else { return finish() }
            let phase = Self.phase(for: error)
            Self.logger.notice("Dictionary sync stopped: \(String(describing: error), privacy: .public)")
            status.phase = phase
            symbolPhase = .failed
            scheduleRetry()
        }
        finish()
    }

    private func finish() {
        isRunning = false
        if runAgain {
            runAgain = false
            requestSync(after: .seconds(1))
        }
    }

    private static func phase(for error: Error) -> DictionarySyncPhase {
        switch error as? DictionarySyncError {
        case .driveUnavailable: return .driveOff
        case .notDownloaded: return .waitingForDownload
        case .unreadableFile: return .unreadable
        default: return .failed
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

    private func scheduleRetry() {
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: Self.retryDelay)
            guard !Task.isCancelled else { return }
            await self?.runPass()
        }
    }
}

/// Which saves are the sync's business: those that touch the three dictionary models.
private enum DictionarySyncNotifications {
    static let dictionaryEntities: Set<String> = ["VocabularyWord", "WordReplacement", "Snippet"]

    static func touchesDictionary(_ note: Notification) -> Bool {
        let keys: [ModelContext.NotificationKey] = [.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers]
        for key in keys {
            let identifiers = note.userInfo?[key.rawValue] as? [PersistentIdentifier] ?? []
            if identifiers.contains(where: { dictionaryEntities.contains($0.entityName) }) { return true }
        }
        return false
    }
}
