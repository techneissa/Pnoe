import Foundation

/// What a short look at the audio of some processes showed.
enum AudioLevelReading: Sendable, Equatable {
    /// Samples arrived and none rose above `PeakMeter.silenceThreshold`.
    case silent
    /// At least one sample rose above the threshold.
    case sound
    /// No tap could be made (no permission, or CoreAudio refused). The permission is not there, so pausing turns off.
    case unavailable
    /// A tap was or could have been made, but there is no answer for this recording: the meter was busy, took too
    /// long, or no samples arrived in the window. Nothing is pressed this time; the switch stays on.
    case skipped
}

/// What a listening session heard.
struct AudioLevelMeasurement: Sendable, Equatable {
    /// The players' audio, mixed.
    var players: AudioLevelReading

    static let unavailable = AudioLevelMeasurement(players: .unavailable)
    static let skipped = AudioLevelMeasurement(players: .skipped)
}

/// Measures the level of the audio some processes send to the output, which the process list cannot say.
///
/// The process list (`AudioOutputProcesses`) reports a process as playing for as long as it keeps its stream
/// open, and players keep it open after a pause, with silence in it. Only the samples tell playing from lingering.
/// Reading them needs a CoreAudio process tap, which needs the System Audio Recording permission, so it is
/// used only when the user turns on pausing media.
protocol AudioLevelMeasuring: Sendable {
    /// Listens to the mix of `processes` for at most `window` seconds (`ListeningPlan` says when it may stop
    /// sooner). Never throws: no tap is `.unavailable`, any other failure is `.skipped`.
    func measure(processes: [AudioProcess], window: TimeInterval) async -> AudioLevelMeasurement

    /// Whether the System Audio Recording permission is granted. Never shows a prompt.
    func hasPermission() async -> Bool

    /// Asks for the permission if it has not been decided, and says whether it is granted and a tap can be made.
    /// Called when the user turns pausing on.
    func requestPermission() async -> Bool
}

/// When a listening session may stop before its window ends.
enum ListeningPlan {
    /// Listening lasts at least this long, so a
    /// player that is about to produce sound is not judged on a few milliseconds.
    static let minimumWindow: TimeInterval = 0.15

    static func isDone(elapsed: TimeInterval, window: TimeInterval, players: AudioLevelReading) -> Bool {
        // A player making sound answers the question at once.
        elapsed >= window || players == .sound || elapsed >= minimumWindow
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
