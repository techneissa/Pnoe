import Foundation

/// What a short look at the audio of some processes showed.
enum AudioLevelReading: Sendable, Equatable {
    /// Samples arrived and none rose above `PeakMeter.silenceThreshold`.
    case silent
    /// At least one sample rose above the threshold.
    case sound
    /// No reading was possible: no permission, no tap, or no samples arrived in the window.
    case unavailable
}

/// What a listening session heard.
struct AudioLevelMeasurement: Sendable, Equatable {
    /// The players' audio, mixed.
    var players: AudioLevelReading
    /// Pnoe's own audio (its start sound), read separately from the players'. `nil` when it was not asked for.
    /// Heard sound here proves the tap delivers audio right now, so silence in `players` is real.
    var own: AudioLevelReading?

    static func unavailable(includingOwn: Bool) -> AudioLevelMeasurement {
        AudioLevelMeasurement(players: .unavailable, own: includingOwn ? .unavailable : nil)
    }
}

/// Measures the level of the audio some processes send to the output, which the process list cannot say.
///
/// The process list (`AudioOutputProcesses`) reports a process as playing for as long as it keeps its stream
/// open, and players keep it open after a pause, with silence in it. Only the samples tell playing from lingering.
/// Reading them needs a CoreAudio process tap, which needs the System Audio Recording permission, so it is
/// used only when the user turns on pausing media.
protocol AudioLevelMeasuring: Sendable {
    /// Listens to the mix of `processes`, and to Pnoe's own audio separately when `includingOwnProcess` is set,
    /// for at most `window` seconds (`ListeningPlan` says when it may stop sooner). Never throws: any failure
    /// is `.unavailable`.
    func measure(processes: [AudioProcess], includingOwnProcess: Bool, window: TimeInterval) async
        -> AudioLevelMeasurement

    /// Whether the System Audio Recording permission is granted. Never shows a prompt.
    func hasPermission() async -> Bool

    /// Asks for the permission if it has not been decided, and says whether it is granted and a tap can be made.
    /// Called when the user turns pausing on.
    func requestPermission() async -> Bool
}

/// When a listening session may stop before its window ends.
enum ListeningPlan {
    /// Listening to the players alone, or to the players and Pnoe's own audio, lasts at least this long, so a
    /// player that is about to produce sound is not judged on a few milliseconds.
    static let minimumWindow: TimeInterval = 0.15

    static func isDone(
        elapsed: TimeInterval, window: TimeInterval, players: AudioLevelReading, own: AudioLevelReading?
    ) -> Bool {
        if elapsed >= window { return true }
        // A player making sound answers the question at once.
        if players == .sound { return true }
        // Without Pnoe's own audio to wait for, or once it has been heard, the minimum is enough.
        return elapsed >= minimumWindow && (own == nil || own == .sound)
    }
}

/// Running peak of the samples seen in a measuring window.
struct PeakMeter: Sendable, Equatable {
    /// About -60 dBFS: above the noise floor of a decoder that is idle, below any music at a listenable level.
    static let silenceThreshold: Float = 0.001

    private(set) var peak: Float = 0
    private(set) var sampleCount = 0

    mutating func add(_ samples: UnsafeBufferPointer<Float>) {
        for sample in samples {
            // NaN compares false everywhere, so it counts as a sample but never as sound.
            peak = max(peak, abs(sample))
        }
        sampleCount += samples.count
    }

    mutating func add(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { add($0) }
    }

    var reading: AudioLevelReading {
        guard sampleCount > 0 else { return .unavailable }
        return peak > Self.silenceThreshold ? .sound : .silent
    }
}
