import AppKit
import Combine
import Foundation
import SwiftUI

/// Pauses media while Pnoe records and resumes it afterwards.
///
/// macOS has no public API that says whether the "Now Playing" app is playing. Pnoe uses what is public:
/// the CoreAudio process list (`AudioOutputProcesses`) to see that some app is producing audio, and the
/// system Play/Pause media key to pause and resume it. Because the key is a toggle that goes to whichever
/// app is "Now Playing", Pnoe only presses it when audio is running, and presses it again to resume only
/// after it has seen that audio stop.
@MainActor
class PlaybackController: ObservableObject {
    static let shared = PlaybackController()

    /// A pause Pnoe started and still has to undo.
    private struct OwnedPause {
        let id = UUID()
        /// Processes that had audio output running when the key was pressed.
        let playingProcessIDs: Set<pid_t>
        let pressedAt: TimeInterval
        /// Processes from `playingProcessIDs` that stopped output after the key press. Empty until one has.
        var stoppedProcessIDs: Set<pid_t> = []
    }

    /// How long after the key press a process that was not playing before is read as the key having
    /// started playback, which Pnoe then undoes.
    private let startedPlaybackWindow: TimeInterval = 1.5
    /// How long Pnoe waits for the audio to stop before it gives up on resuming. Players keep their
    /// output running for several seconds after a pause (QuickTime Player: about 8 s).
    private let pauseConfirmationTimeout: TimeInterval = 12
    private let pollInterval: Duration = .milliseconds(100)

    private var ownedPause: OwnedPause?
    private var recordingSessionID = UUID()

    @Published var isPauseMediaEnabled: Bool = UserDefaults.standard.bool(forKey: "isPauseMediaEnabled") {
        didSet {
            UserDefaults.standard.set(isPauseMediaEnabled, forKey: "isPauseMediaEnabled")

            if !isPauseMediaEnabled {
                recordingSessionID = UUID()
                ownedPause = nil
            }
        }
    }

    private init() {}

    func beginRecordingSession() -> UUID {
        recordingSessionID = UUID()
        // A new recording inherits a pause whose restoration has not completed.
        return recordingSessionID
    }

    func pauseMedia(sessionID: UUID) async {
        guard canAct(sessionID: sessionID) else { return }
        // A pause that never showed the audio stopping is stale and no longer owned.
        if let ownedPause, ownedPause.stoppedProcessIDs.isEmpty,
            Self.now - ownedPause.pressedAt >= pauseConfirmationTimeout
        {
            self.ownedPause = nil
        }
        // Media Pnoe already paused for an earlier recording stays paused; the key is not pressed twice.
        guard ownedPause == nil else { return }
        guard !AudioOutputProcesses.currentProcessIDs().isEmpty else { return }

        try? await Task.sleep(for: .milliseconds(50))
        guard canAct(sessionID: sessionID) else { return }

        // Read again right before the key press: the audio may have stopped during the delay.
        let playingProcessIDs = AudioOutputProcesses.currentProcessIDs()
        guard !playingProcessIDs.isEmpty else { return }

        // Own the pause from the moment the key is sent, whether or not this task is cancelled later.
        let pause = OwnedPause(playingProcessIDs: playingProcessIDs, pressedAt: Self.now)
        ownedPause = pause
        Self.sendMediaPlayPauseKey()

        await undoIfPlaybackStarted(pause, sessionID: sessionID)
    }

    func resumeMedia(sessionID: UUID) async {
        guard canAct(sessionID: sessionID), var pause = ownedPause else { return }

        // The key only toggles, so it is pressed again only once the audio is seen to have stopped. Without
        // that proof the first press may have reached an app that was not playing, and a second press
        // would start it.
        while pause.stoppedProcessIDs.isEmpty {
            guard canRestore(pause, sessionID: sessionID) else { return }

            let currentProcessIDs = AudioOutputProcesses.currentProcessIDs()
            pause.stoppedProcessIDs = pause.playingProcessIDs.subtracting(currentProcessIDs)
            if !pause.stoppedProcessIDs.isEmpty { break }

            guard Self.now - pause.pressedAt < pauseConfirmationTimeout else {
                ownedPause = nil
                return
            }
            guard (try? await Task.sleep(for: pollInterval)) != nil else { return }
        }
        ownedPause = pause

        let delay = MediaController.shared.audioResumptionDelay
        if delay > 0 {
            guard (try? await Task.sleep(for: .seconds(delay))) != nil else { return }
        }
        guard canRestore(pause, sessionID: sessionID) else { return }

        // Something else is playing now, or the user already resumed the player: leave it alone.
        let currentProcessIDs = AudioOutputProcesses.currentProcessIDs()
        let startedElsewhere = !currentProcessIDs.subtracting(pause.playingProcessIDs).isEmpty
        let resumedByUser = !currentProcessIDs.isDisjoint(with: pause.stoppedProcessIDs)
        guard !startedElsewhere, !resumedByUser else {
            ownedPause = nil
            return
        }

        Self.sendMediaPlayPauseKey()
        ownedPause = nil
    }

    private func canAct(sessionID: UUID) -> Bool {
        !Task.isCancelled && isPauseMediaEnabled && sessionID == recordingSessionID
    }

    private func canRestore(_ pause: OwnedPause, sessionID: UUID) -> Bool {
        canAct(sessionID: sessionID) && ownedPause?.id == pause.id
    }

    /// If the key press made an app that was not playing start, press it again so nothing new plays.
    /// This happens when the "Now Playing" app is not the app producing the audio, for example during a call.
    private func undoIfPlaybackStarted(_ pause: OwnedPause, sessionID: UUID) async {
        while Self.now - pause.pressedAt < startedPlaybackWindow {
            guard (try? await Task.sleep(for: pollInterval)) != nil else { return }
            guard canRestore(pause, sessionID: sessionID) else { return }

            let currentProcessIDs = AudioOutputProcesses.currentProcessIDs()
            if !currentProcessIDs.subtracting(pause.playingProcessIDs).isEmpty {
                Self.sendMediaPlayPauseKey()
                ownedPause = nil
                return
            }
        }
    }

    private static var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    /// Simulate the hardware media Play/Pause key (NX_KEYTYPE_PLAY = 16).
    private static func sendMediaPlayPauseKey() {
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
