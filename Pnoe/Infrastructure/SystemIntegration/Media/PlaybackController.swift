import AppKit
import Combine
import Foundation
import SwiftUI

/// Pauses media while Pnoe records and resumes it afterwards.
///
/// macOS has no public API that says whether the "Now Playing" app is playing. Pnoe uses what is public:
/// the CoreAudio process list (`AudioOutputProcesses`) to see which known media players have audio running,
/// and the system Play/Pause media key to pause and resume. The key is a toggle that goes to whichever app is
/// "Now Playing", so it is a pair: one press to pause, one press to put things back.
///
/// - Every press, the first one, the undo and the resume, needs a fresh read of the audio processes that shows
///   no call (`MediaApplications`): never touch media while a call app or a microphone user is active.
/// - The first press happens only when a known player is playing.
/// - A press is undone only when a player that was not playing starts right after it, no process that was
///   playing has gone silent, and nothing else says what started it. When Pnoe cannot tell, it does nothing.
/// - Once Pnoe has paused something it presses again when the recording ends, whatever else happened in
///   between, unless the user or another app changed playback meanwhile.
@MainActor
class PlaybackController: ObservableObject {
    static let shared = PlaybackController()

    /// A pause Pnoe started and still has to undo.
    private struct OwnedPause {
        let id = UUID()
        /// The known players that had audio running when the key was pressed.
        let playingProcessIDs: Set<pid_t>
        let pressedAt: TimeInterval
        /// The players from `playingProcessIDs` that have been seen silent after the press: the ones the press
        /// paused. A player that was silent and is playing again was resumed by someone else.
        var silentProcessIDs: Set<pid_t> = []
    }

    /// What the latest read of the audio processes says about the pause.
    private enum Assessment {
        /// No pause is owned any more, or it is a different one.
        case gone
        /// A call is going on: nothing is pressed.
        case callActive
        /// A player that was not playing started right after the press, and no paused player has gone silent.
        case pressStartedPlayer
        /// Another known player started later, or a player the press paused is playing again.
        case playbackChangedByOthers
        case unchanged
    }

    /// How long after the key press a new player is read as started by the press. Short on purpose: a later
    /// start is more likely an autoplaying page than the Now Playing app.
    private let startedPlaybackWindow: TimeInterval = 0.6
    /// How long the monitor watches one pause. A longer recording is still resumed, without the watching.
    private let monitorLifetime: TimeInterval = 30 * 60
    private let pollInterval: Duration = .milliseconds(200)

    private let mediaApplications: MediaApplications
    private let readAudioProcesses: @Sendable () async -> [AudioProcess]
    private let pressKey: @MainActor () -> Void

    private var ownedPause: OwnedPause?
    private var lastActivity: MediaApplications.Activity?
    private var monitorTask: Task<Void, Never>?
    private var recordingSessionID = UUID()
    private var terminationObserver: NSObjectProtocol?

    @Published var isPauseMediaEnabled: Bool = UserDefaults.standard.bool(forKey: "isPauseMediaEnabled") {
        didSet {
            UserDefaults.standard.set(isPauseMediaEnabled, forKey: "isPauseMediaEnabled")
            // A pause Pnoe already started is still undone when the recording ends, whatever the toggle says.
        }
    }

    init(
        mediaApplications: MediaApplications = .standard,
        readAudioProcesses: @escaping @Sendable () async -> [AudioProcess] = { await AudioOutputProcesses.snapshot() },
        pressKey: @escaping @MainActor () -> Void = { PlaybackController.sendMediaPlayPauseKey() }
    ) {
        self.mediaApplications = mediaApplications
        self.readAudioProcesses = readAudioProcesses
        self.pressKey = pressKey

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreBeforeQuit() }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    func beginRecordingSession() -> UUID {
        recordingSessionID = UUID()
        // A new recording inherits a pause whose restoration has not completed.
        return recordingSessionID
    }

    // MARK: - Pausing

    func pauseMedia(sessionID: UUID) async {
        guard canStartPause(sessionID: sessionID), ownedPause == nil else { return }
        guard await isKnownPlayerPlayingAlone() else { return }

        try? await Task.sleep(for: .milliseconds(50))
        guard canStartPause(sessionID: sessionID), ownedPause == nil else { return }

        // Read again right before the key press: the audio may have stopped, or a call started, during the delay.
        let activity = await currentActivity()
        guard canStartPause(sessionID: sessionID), ownedPause == nil,
            !activity.isCallActive, !activity.playingProcessIDs.isEmpty
        else { return }

        // Own the pause from the moment the key is sent, whether or not this task is cancelled later.
        let pause = OwnedPause(playingProcessIDs: activity.playingProcessIDs, pressedAt: Self.now)
        ownedPause = pause
        pressKey()
        startMonitor(for: pause.id)
    }

    private func canStartPause(sessionID: UUID) -> Bool {
        !Task.isCancelled && isPauseMediaEnabled && sessionID == recordingSessionID
    }

    /// A known player is playing and no call is going on.
    private func isKnownPlayerPlayingAlone() async -> Bool {
        let activity = await currentActivity()
        return !activity.isCallActive && !activity.playingProcessIDs.isEmpty
    }

    // MARK: - Resuming

    func resumeMedia(sessionID: UUID) async {
        // A pause is undone whatever the toggle says now. A newer recording takes over a pause it inherited.
        guard let pauseID = ownedPause?.id, sessionID == recordingSessionID, !Task.isCancelled else { return }

        guard await settle(pauseID, sessionID: sessionID) else { return }

        let delay = MediaController.shared.audioResumptionDelay
        if delay > 0 {
            guard (try? await Task.sleep(for: .seconds(delay))) != nil else { return }
            // Everything is read again after the wait: the state may have changed during it.
            guard await settle(pauseID, sessionID: sessionID) else { return }
        }

        pressKey()
        finish(pauseID)
    }

    /// Reads the audio processes and decides whether the resume press may happen now. Presses the undo
    /// itself when the first press started a player. Returns `true` when the resume press may happen.
    /// A `false` means the pause is finished, or is left to a newer recording after a cancel.
    private func settle(_ pauseID: UUID, sessionID: UUID) async -> Bool {
        let activity = await currentActivity()
        guard !Task.isCancelled, sessionID == recordingSessionID else { return false }

        switch assess(pauseID, activity) {
        case .gone:
            return false
        case .callActive, .playbackChangedByOthers:
            finish(pauseID)
            return false
        case .pressStartedPlayer:
            pressKey()
            finish(pauseID)
            return false
        case .unchanged:
            return true
        }
    }

    // MARK: - Watching a pause

    private func finish(_ pauseID: UUID) {
        guard ownedPause?.id == pauseID else { return }
        ownedPause = nil
        monitorTask?.cancel()
        monitorTask = nil
    }

    /// One read of the audio processes, remembered for the quit path.
    private func currentActivity() async -> MediaApplications.Activity {
        let activity = mediaApplications.activity(in: await readAudioProcesses())
        lastActivity = activity
        return activity
    }

    /// Folds `activity` into the stored pause, which is read fresh here and never passed around, and says
    /// what it means. The silence of each paused player is tracked on its own.
    private func assess(_ pauseID: UUID, _ activity: MediaApplications.Activity) -> Assessment {
        guard var pause = ownedPause, pause.id == pauseID else { return .gone }

        pause.silentProcessIDs.formUnion(pause.playingProcessIDs.subtracting(activity.playingProcessIDs))
        ownedPause = pause

        if activity.isCallActive { return .callActive }

        let newPlayers = activity.playingProcessIDs.subtracting(pause.playingProcessIDs)
        if !newPlayers.isEmpty {
            let isRightAfterPress = Self.now - pause.pressedAt < startedPlaybackWindow
            return isRightAfterPress && pause.silentProcessIDs.isEmpty ? .pressStartedPlayer : .playbackChangedByOthers
        }
        if !pause.silentProcessIDs.isDisjoint(with: activity.playingProcessIDs) {
            return .playbackChangedByOthers
        }
        return .unchanged
    }

    /// Polls the audio processes off the main actor and keeps the pause up to date: undoes a press that
    /// started a player, notes which paused players went silent, and drops the pause when someone else
    /// changes playback. It stops when the pause ends, when the recording is resumed, or after
    /// `monitorLifetime`.
    private func startMonitor(for pauseID: UUID) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            let startedAt = Self.now
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.pollInterval ?? .milliseconds(200))
                guard !Task.isCancelled, let self else { return }

                let activity = await self.currentActivity()
                guard !Task.isCancelled else { return }

                switch self.assess(pauseID, activity) {
                case .gone:
                    return
                case .playbackChangedByOthers:
                    self.finish(pauseID)
                    return
                case .pressStartedPlayer:
                    self.pressKey()
                    self.finish(pauseID)
                    return
                case .callActive, .unchanged:
                    break
                }
                if Self.now - startedAt > self.monitorLifetime { return }
            }
        }
    }

    /// Pnoe is quitting in the middle of a recording: put the media back the way it was, unless the last read
    /// of the audio processes showed a call.
    private func restoreBeforeQuit() {
        monitorTask?.cancel()
        monitorTask = nil
        guard ownedPause != nil else { return }
        ownedPause = nil
        guard lastActivity?.isCallActive != true else { return }
        pressKey()
    }

    private static var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    /// Simulate the hardware media Play/Pause key (NX_KEYTYPE_PLAY = 16).
    static func sendMediaPlayPauseKey() {
        func post(down: Bool) {
            let flags: UInt = down ? 0xa00 : 0xb00
            let data1 = Int((16 << 16) | ((down ? 0xa : 0xb) << 8))
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
        post(down: true)
        post(down: false)
    }
}
