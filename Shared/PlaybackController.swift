import AppKit
import Combine
import Foundation
import SwiftUI
import os

/// Pauses media while Pnoe records and resumes it afterwards.
///
/// macOS has no public API that says whether the "Now Playing" app is playing. Pnoe uses what is public:
/// the CoreAudio process list (`AudioOutputProcesses`) to see which known media players have audio running,
/// and the system Play/Pause media key to pause and resume. The key is a toggle that goes to whichever app is
/// "Now Playing", so it is a pair: one press to pause, one press to put things back.
///
/// - Every press, the first one, the undo and the resume, needs a fresh read of the audio processes that shows
///   no call (`MediaApplications`): never touch media while a call app or a microphone user is active.
/// - The first press happens only when a known player is playing. It also
///   needs sound in the players' audio: a player paused a moment ago still has its stream open, with silence.
///   Pausing is on only while the System Audio Recording permission is granted; without it the switch turns
///   itself off (`needsPermission`), and nothing is pressed on the output flag alone.
/// - A press is undone only when a player that was not playing starts right after it, no process that was
///   playing has gone silent, and nothing else says what started it. When Pnoe cannot tell, it does nothing.
/// - Once Pnoe has paused something it presses again when the recording ends, whatever else happened in
///   between, unless the user or another app changed playback meanwhile.
@MainActor
class PlaybackController: ObservableObject {
    static let pauseMediaKey = "isPauseMediaEnabled"

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
    private let clock: @MainActor () -> TimeInterval
    /// The longest a level check may take from its start, the permission prompt included. Past it the output flag
    /// decides.
    private let levelDeadline: TimeInterval
    /// How long the level check listens to the players alone: long enough for a few audio buffers, short enough to
    /// add little to the start of a recording.
    private let levelWindow: TimeInterval = ListeningPlan.minimumWindow
    /// How old a listening session started before the start sound may be and still count for a pause.
    private let probeFreshness: TimeInterval = 3

    /// A listening session started when the start sound was played, so that it overlaps the sound however long the
    /// recording takes to start.
    private struct LevelProbe {
        let startedAt: TimeInterval
        let task: Task<ProbeResult, Never>
    }
    /// What a probe heard, and which players it listened to. `measurement` is `nil` when nothing was playing.
    private struct ProbeResult {
        let measurement: AudioLevelMeasurement?
        let playerPIDs: Set<pid_t>
    }
    private var pendingProbe: LevelProbe?

    private var ownedPause: OwnedPause?
    private var monitorTask: Task<Void, Never>?
    private var recordingSessionID = UUID()
    private var isQuitting = false
    private var terminationObserver: NSObjectProtocol?
    /// How long the quit path waits for a fresh read of the audio processes before it gives up and presses nothing.
    private let quitReadTimeout: TimeInterval = 0.2

    /// Off by default. It is on only while the System Audio Recording permission is granted: turning it on asks for
    /// the permission, and a refusal (or a tap that cannot be made) turns it off again with `needsPermission` set.
    @Published var isPauseMediaEnabled: Bool {
        didSet {
            defaults.set(isPauseMediaEnabled, forKey: Self.pauseMediaKey)
            // A pause Pnoe already started is still undone when the recording ends, whatever the toggle says.
            guard isPauseMediaEnabled != oldValue else { return }
            if isPauseMediaEnabled {
                needsPermission = false
                requestPermissionTask?.cancel()
                requestPermissionTask = Task { [weak self] in
                    guard let self else { return }
                    let granted = await self.levelMeter?.requestPermission() ?? false
                    guard !Task.isCancelled, self.isPauseMediaEnabled, !granted else { return }
                    self.switchOffForMissingPermission()
                }
            } else {
                requestPermissionTask?.cancel()
            }
        }
    }

    /// Pausing was switched off because the permission is missing; the settings show a note until it is turned on
    /// again.
    @Published private(set) var needsPermission = false
    private var requestPermissionTask: Task<Void, Never>?

    static let permissionSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!

    private func switchOffForMissingPermission() {
        needsPermission = true
        isPauseMediaEnabled = false
    }

    /// Checked at launch and before every recording, without a prompt. A permission that was revoked since turns
    /// the switch off.
    private func permissionIsGranted() async -> Bool {
        guard let levelMeter, await levelMeter.hasPermission() else {
            if isPauseMediaEnabled { switchOffForMissingPermission() }
            return false
        }
        return true
    }

    init(
        mediaApplications: MediaApplications = .standard,
        readAudioProcesses: @escaping @Sendable () async -> [AudioProcess] = { await AudioOutputProcesses.snapshot() },
        pressKey: @escaping @MainActor () -> Void = { PlaybackController.sendMediaPlayPauseKey() },
        resumptionDelay: @escaping @MainActor () -> Double = { 0 },
        levelMeter: AudioLevelMeasuring? = nil,
        defaults: UserDefaults = .standard,
        levelDeadline: TimeInterval = 0.5,
        clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.mediaApplications = mediaApplications
        self.readAudioProcesses = readAudioProcesses
        self.pressKey = pressKey
        self.resumptionDelay = resumptionDelay
        self.levelMeter = levelMeter
        self.defaults = defaults
        self.levelDeadline = levelDeadline
        self.clock = clock
        self.isPauseMediaEnabled = defaults.bool(forKey: Self.pauseMediaKey)
        if isPauseMediaEnabled {
            Task { [weak self] in _ = await self?.permissionIsGranted() }
        }

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
        guard await permissionIsGranted() else { return }
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

    /// Call right before Pnoe plays its start sound. With pausing on, this starts listening to the players
    /// and to Pnoe's own audio at once, so the start sound is inside the listening window however long the recording
    /// takes to start. `pauseMedia` uses the result. Does nothing when pausing is off, and makes no
    /// tap when no known player is playing.
    func beginLevelProbe() {
        pendingProbe?.task.cancel()
        pendingProbe = nil
        guard isPauseMediaEnabled, let levelMeter, !isQuitting else { return }

        pendingProbe = LevelProbe(
            startedAt: clock(),
            task: Task { [weak self] in
                guard let self, let players = await self.knownPlayersPlayingAlone() else {
                    return ProbeResult(measurement: nil, playerPIDs: [])
                }
                let measurement = await self.measureWithDeadline(levelMeter, players)
                return ProbeResult(measurement: measurement, playerPIDs: Set(players.map(\.pid)))
            }
        )
    }

    /// A press needs sound in the players' audio. A tap that fails or delivers nothing turns pausing off: the
    /// output flag alone never decides.
    private func levelCheckAllowsPause(for players: [AudioProcess]) async -> Bool {
        guard let levelMeter else { return false }

        var measurement: AudioLevelMeasurement?
        if let probe = pendingProbe, clock() - probe.startedAt < probeFreshness {
            pendingProbe = nil
            let result = await probe.task.value
            // The probe vouches only for the players it listened to; a player it did not hear needs a new look.
            if Set(players.map(\.pid)).isSubset(of: result.playerPIDs) {
                measurement = result.measurement
            }
        } else {
            pendingProbe?.task.cancel()
            pendingProbe = nil
        }
        if measurement == nil {
            measurement = await measureWithDeadline(levelMeter, players)
        }

        switch measurement?.players ?? .unavailable {
        case .sound:
            return true
        case .silent:
            return false
        case .unavailable:
            switchOffForMissingPermission()
            return false
        }
    }

    /// Asks the meter and gives up after `levelDeadline`, whatever the meter does: a CoreAudio call can block while
    /// the permission prompt is up. The meter's work is left to finish on its own.
    private func measureWithDeadline(
        _ meter: AudioLevelMeasuring, _ players: [AudioProcess]
    ) async -> AudioLevelMeasurement {
        let window = levelWindow
        let deadline = levelDeadline
        let unavailable = AudioLevelMeasurement.unavailable(includingOwn: false)
        return await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let resumeOnce: @Sendable (AudioLevelMeasurement) -> Void = { measurement in
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: measurement) }
            }
            Task.detached {
                resumeOnce(
                    await meter.measure(processes: players, includingOwnProcess: false, window: window))
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(deadline))
                resumeOnce(unavailable)
            }
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
