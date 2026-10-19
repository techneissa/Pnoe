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

/// Measures the level of the audio some processes send to the output, which the process list cannot say.
///
/// The process list (`AudioOutputProcesses`) reports a process as playing for as long as it keeps its stream
/// open, and players keep it open after a pause, with silence in it. Only the samples tell playing from lingering.
/// Reading them needs a CoreAudio process tap, which needs the System Audio Recording permission, so this is
/// optional and off by default.
protocol AudioLevelMeasuring: Sendable {
    /// Listens to the mix of `processes` for `window` seconds. Never throws: any failure is `.unavailable`.
    func measure(processes: [AudioProcess], window: TimeInterval) async -> AudioLevelReading
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
