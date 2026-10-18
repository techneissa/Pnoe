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
/// - The first press happens only when a known player (`MediaApplications`) is playing and no call is going on.
/// - If a player that was not playing starts right after the press, the press started it, and is undone.
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
        /// Every process in `playingProcessIDs` has been seen silent after the press.
        var silenceSeen = false
    }

    /// How long after the key press a player that was not playing before is read as the key having started it.
    private let startedPlaybackWindow: TimeInterval = 1.5
    /// How long the monitor watches one pause. A longer recording is still resumed, without the watching.
    private let monitorLifetime: TimeInterval = 30 * 60
    private let pollInterval: Duration = .milliseconds(200)

    private let mediaApplications: MediaApplications
    private let readAudioProcesses: @Sendable () async -> [AudioProcess]
    private let pressKey: @MainActor () -> Void

    private var ownedPause: OwnedPause?
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

    func pauseMedia(sessionID: UUID) async {
        guard canStartPause(sessionID: sessionID), ownedPause == nil else { return }
        guard await isKnownPlayerPlayingAlone() else { return }

        try? await Task.sleep(for: .milliseconds(50))
        guard canStartPause(sessionID: sessionID), ownedPause == nil else { return }

        // Read again right before the key press: the audio may have stopped, or a call started, during the delay.
        let activity = mediaApplications.activity(in: await readAudioProcesses())
        guard canStartPause(sessionID: sessionID), ownedPause == nil,
            !activity.isCallActive, !activity.playingProcessIDs.isEmpty
        else { return }

        // Own the pause from the moment the key is sent, whether or not this task is cancelled later.
        let pause = OwnedPause(playingProcessIDs: activity.playingProcessIDs, pressedAt: Self.now)
        ownedPause = pause
        pressKey()
        startMonitor(for: pause)
    }

    func resumeMedia(sessionID: UUID) async {
        // A pause is undone whatever the toggle says now. A newer recording takes over a pause it inherited.
        guard let pause = ownedPause, sessionID == recordingSessionID, !Task.isCancelled else { return }

        let activity = mediaApplications.activity(in: await readAudioProcesses())
        guard canRestore(pause, sessionID: sessionID) else { return }

        // A very short recording: the first press started a player that was not playing, and the monitor has
        // not undone it yet.
        if Self.now - pause.pressedAt < startedPlaybackWindow,
            !activity.playingProcessIDs.subtracting(pause.playingProcessIDs).isEmpty
        {
            pressKey()
            finish(pause)
            return
        }

        // Something other than Pnoe changed playback, or a call has started: leave it alone.
        guard !activity.isCallActive, !playbackChangedByOthers(pause, now: activity) else {
            finish(pause)
            return
        }

        let delay = MediaController.shared.audioResumptionDelay
        if delay > 0 {
            guard (try? await Task.sleep(for: .seconds(delay))) != nil else { return }
            guard canRestore(pause, sessionID: sessionID) else { return }
            let latest = mediaApplications.activity(in: await readAudioProcesses())
            guard canRestore(pause, sessionID: sessionID) else { return }
            guard !latest.isCallActive, !playbackChangedByOthers(pause, now: latest) else {
                finish(pause)
                return
            }
        }

        pressKey()
        finish(pause)
    }

    // MARK: - Starting a pause

    private func canStartPause(sessionID: UUID) -> Bool {
        !Task.isCancelled && isPauseMediaEnabled && sessionID == recordingSessionID
    }

    /// A known player is playing and no call is going on.
    private func isKnownPlayerPlayingAlone() async -> Bool {
        let activity = mediaApplications.activity(in: await readAudioProcesses())
        return !activity.isCallActive && !activity.playingProcessIDs.isEmpty
    }

    // MARK: - Watching a pause

    private func canRestore(_ pause: OwnedPause, sessionID: UUID) -> Bool {
        !Task.isCancelled && sessionID == recordingSessionID && ownedPause?.id == pause.id
    }

    private func finish(_ pause: OwnedPause) {
        guard ownedPause?.id == pause.id else { return }
        ownedPause = nil
        monitorTask?.cancel()
        monitorTask = nil
    }

    /// The player that Pnoe paused is playing again after it was silent, or another known player started.
    private func playbackChangedByOthers(_ pause: OwnedPause, now activity: MediaApplications.Activity) -> Bool {
        if activity.playingProcessIDs.subtracting(pause.playingProcessIDs).isEmpty == false {
            return true
        }
        return pause.silenceSeen && !activity.playingProcessIDs.isEmpty
    }

    /// Polls the audio processes off the main actor and keeps the pause up to date: undoes a press that
    /// started playback, notes when the paused players went silent, and drops the pause when someone else
    /// changes playback. It stops when the pause ends, when the recording is resumed, or after
    /// `monitorLifetime`.
    private func startMonitor(for pause: OwnedPause) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.pollInterval ?? .milliseconds(200))
                guard !Task.isCancelled, let self else { return }

                let activity = self.mediaApplications.activity(in: await self.readAudioProcesses())
                guard !Task.isCancelled, self.ownedPause?.id == pause.id else { return }

                if Self.now - pause.pressedAt < self.startedPlaybackWindow {
                    // A player that was not playing before has started: the press started it. Press again.
                    if !activity.playingProcessIDs.subtracting(pause.playingProcessIDs).isEmpty {
                        self.pressKey()
                        self.finish(pause)
                        return
                    }
                } else if self.playbackChangedByOthers(pause, now: activity) {
                    self.finish(pause)
                    return
                }

                if activity.playingProcessIDs.isDisjoint(with: pause.playingProcessIDs) {
                    self.ownedPause?.silenceSeen = true
                }
                if Self.now - pause.pressedAt > self.monitorLifetime { return }
            }
        }
    }

    /// Pnoe is quitting in the middle of a recording: put the media back the way it was.
    private func restoreBeforeQuit() {
        monitorTask?.cancel()
        monitorTask = nil
        guard ownedPause != nil else { return }
        ownedPause = nil
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
