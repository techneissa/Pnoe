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
/// - The first press happens only when a known player is playing. With the optional level check on, it also
///   needs sound in the players' audio: a player paused a moment ago still has its stream open, with silence.
/// - A press is undone only when a player that was not playing starts right after it, no process that was
///   playing has gone silent, and nothing else says what started it. When Pnoe cannot tell, it does nothing.
/// - Once Pnoe has paused something it presses again when the recording ends, whatever else happened in
///   between, unless the user or another app changed playback meanwhile.
@MainActor
class PlaybackController: ObservableObject {
    static let pauseMediaKey = "isPauseMediaEnabled"
    static let levelCheckKey = "isMediaLevelCheckEnabled"
    /// Set once a level check has heard sound, which proves the tap works (permission granted). Until then a
    /// "silent" reading is not believed: without the permission a tap can deliver silence.
    static let levelCheckVerifiedKey = "isMediaLevelCheckVerified"

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
    private let resumptionDelay: @MainActor () -> Double
    private let levelMeter: AudioLevelMeasuring?
    private let defaults: UserDefaults
    /// How long the level check listens. Long enough for a few audio buffers, short enough to add little to the
    /// start of a recording.
    private let levelWindow: TimeInterval = 0.15

    private var ownedPause: OwnedPause?
    private var monitorTask: Task<Void, Never>?
    private var recordingSessionID = UUID()
    private var isQuitting = false
    private var terminationObserver: NSObjectProtocol?
    /// How long the quit path waits for a fresh read of the audio processes before it gives up and presses nothing.
    private let quitReadTimeout: TimeInterval = 0.2

    @Published var isPauseMediaEnabled: Bool {
        didSet {
            defaults.set(isPauseMediaEnabled, forKey: Self.pauseMediaKey)
            // A pause Pnoe already started is still undone when the recording ends, whatever the toggle says.
        }
    }

    /// Off by default. Listens to the players' audio before pausing, so music that was paused a moment ago is not
    /// started again. Needs the System Audio Recording permission, which macOS asks for the first time it runs.
    @Published var isLevelCheckEnabled: Bool {
        didSet { defaults.set(isLevelCheckEnabled, forKey: Self.levelCheckKey) }
    }

    init(
        mediaApplications: MediaApplications = .standard,
        readAudioProcesses: @escaping @Sendable () async -> [AudioProcess] = { await AudioOutputProcesses.snapshot() },
        pressKey: @escaping @MainActor () -> Void = { PlaybackController.sendMediaPlayPauseKey() },
        resumptionDelay: @escaping @MainActor () -> Double = { 0 },
        levelMeter: AudioLevelMeasuring? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.mediaApplications = mediaApplications
        self.readAudioProcesses = readAudioProcesses
        self.pressKey = pressKey
        self.resumptionDelay = resumptionDelay
        self.levelMeter = levelMeter
        self.defaults = defaults
        self.isPauseMediaEnabled = defaults.bool(forKey: Self.pauseMediaKey)
        self.isLevelCheckEnabled = defaults.bool(forKey: Self.levelCheckKey)

        // Delivered on the posting thread (the main thread when the app terminates) and before it returns, so
        // the quit path has run before the process exits.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
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
        guard let playing = await knownPlayersPlayingAlone() else { return }

        try? await Task.sleep(for: .milliseconds(50))
        guard canStartPause(sessionID: sessionID), ownedPause == nil else { return }

        // Players that still hold their stream open after a pause are told from playing ones by their samples.
        guard await levelCheckAllowsPause(for: playing) else { return }
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
        !Task.isCancelled && !isQuitting && isPauseMediaEnabled && sessionID == recordingSessionID
    }

    /// The known players that have output running, when there are some and no call is going on.
    private func knownPlayersPlayingAlone() async -> [AudioProcess]? {
        let processes = await readAudioProcesses()
        let activity = mediaApplications.activity(in: processes)
        guard !activity.isCallActive, !activity.playingProcessIDs.isEmpty else { return nil }
        return processes.filter { activity.playingProcessIDs.contains($0.pid) }
    }

    /// With the level check on, a press needs sound in the players' audio. Whenever the check cannot say
    /// (it is off, the tap failed, no samples came, or silence has never been told from a missing permission)
    /// the output flag decides, as it did before the check existed.
    private func levelCheckAllowsPause(for players: [AudioProcess]) async -> Bool {
        guard isLevelCheckEnabled, let levelMeter else { return true }
        let reading = await levelMeter.measure(processes: players, window: levelWindow)
        switch reading {
        case .sound:
            defaults.set(true, forKey: Self.levelCheckVerifiedKey)
            return true
        case .silent:
            return !defaults.bool(forKey: Self.levelCheckVerifiedKey)
        case .unavailable:
            return true
        }
    }

    // MARK: - Resuming

    func resumeMedia(sessionID: UUID) async {
        // A pause is undone whatever the toggle says now. A newer recording takes over a pause it inherited.
        guard let pauseID = ownedPause?.id, sessionID == recordingSessionID, !Task.isCancelled else { return }

        guard await settle(pauseID, sessionID: sessionID) else { return }

        let delay = resumptionDelay()
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

    private func currentActivity() async -> MediaApplications.Activity {
        mediaApplications.activity(in: await readAudioProcesses())
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

    /// Pnoe is quitting in the middle of a recording: put the media back the way it was. The audio processes
    /// are read once more, for at most `quitReadTimeout`, and nothing is pressed when the read fails, times out,
    /// shows a call, or shows that someone else changed playback. A pause that has not started yet never will.
    private func restoreBeforeQuit() {
        isQuitting = true
        monitorTask?.cancel()
        monitorTask = nil
        guard let pauseID = ownedPause?.id else { return }

        let processes = readAudioProcessesBlocking(timeout: quitReadTimeout)
        let activity = processes.map { mediaApplications.activity(in: $0) }
        let assessment = activity.map { assess(pauseID, $0) }
        ownedPause = nil

        switch assessment {
        case .unchanged, .pressStartedPlayer:
            pressKey()
        default:
            break
        }
    }

    /// One read of the audio processes from a synchronous caller, on a background task. `nil` on timeout.
    private func readAudioProcessesBlocking(timeout: TimeInterval) -> [AudioProcess]? {
        final class Box: @unchecked Sendable {
            var processes: [AudioProcess]?
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let read = readAudioProcesses
        Task.detached {
            let processes = await read()
            box.processes = processes
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success ? box.processes : nil
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
