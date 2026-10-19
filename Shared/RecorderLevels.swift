import CoreGraphics
import Foundation

// The recorder's level display: how a decibel reading becomes a 0...1 level, the ring buffer
// that keeps the last second or two of levels, and the geometry of the Bars and Wave styles.
// Plain values with no dependency on the rest of the app, so the unit tests compile this
// file directly.

/// How the recorder draws the live input level.
enum RecorderLevelDisplay: String, CaseIterable, Identifiable {
    /// Vertical strips, one per recent level, newest at the trailing end.
    case bars
    /// A continuous mirrored waveform through the same levels.
    case wave

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bars: return String(localized: "Bars")
        case .wave: return String(localized: "Wave")
        }
    }
}

enum RecorderLevelMetrics {
    /// How often the recorder takes a level while recording.
    static let samplesPerSecond: Double = 30
    /// What the ring buffer keeps: two seconds.
    static let historyCapacity = 60
    /// Bars shown, one per level: the last second.
    static let barCount = 30
    /// Levels the wave goes through: the whole history.
    static let waveSampleCount = historyCapacity
    /// Width of the Bars and Wave display: 30 bars of 1.5 pt with 1 pt gaps.
    static let meterWidth = CGFloat(barCount) * 2.5 - 1
}

/// Turns the recorder's decibel reading into the 0...1 level the display draws.
enum LevelMapping {
    /// Room noise on a laptop microphone sits around -60 to -50 dBFS, so everything under this
    /// reads as a flat line.
    static let floorDecibels: Float = -50
    /// Normal speech lands between -35 and -20 dBFS (RMS). At this level and above the display is
    /// full, so a shout is clipped instead of overflowing the view.
    static let ceilingDecibels: Float = -18

    /// Linear in decibels between the floor and the ceiling, clipped to 0...1. An unreadable
    /// value (NaN, minus infinity) is silence.
    static func level(fromDecibels decibels: Float) -> Float {
        guard decibels.isFinite else { return decibels == .infinity ? 1 : 0 }
        let span = ceilingDecibels - floorDecibels
        return min(1, max(0, (decibels - floorDecibels) / span))
    }

    /// Fast attack, slow release: a rise shows at once, a fall decays by `release` per sample,
    /// so a short syllable still reads as a bar and the display does not flicker between buffers.
    static func smoothed(previous: Float, next: Float, release: Float = 0.25) -> Float {
        next >= previous ? next : previous + (next - previous) * release
    }
}

/// A fixed-size ring of the most recent levels, oldest overwritten first. A value type: the
/// recorder samples into its copy and the views draw from a snapshot of it.
struct LevelHistory: Equatable {
    let capacity: Int
    private var storage: [Float]
    /// Index the next level is written to.
    private var next = 0
    private(set) var count = 0

    init(capacity: Int = RecorderLevelMetrics.historyCapacity) {
        self.capacity = max(1, capacity)
        storage = Array(repeating: 0, count: max(1, capacity))
    }

    /// Stores a level, clipped to 0...1. NaN is stored as silence.
    mutating func append(_ level: Float) {
        storage[next] = level.isNaN ? 0 : min(1, max(0, level))
        next = (next + 1) % capacity
        count = min(capacity, count + 1)
    }

    mutating func removeAll() {
        next = 0
        count = 0
    }

    /// The newest level, or `nil` while the history is empty.
    var latest: Float? {
        count > 0 ? storage[(next - 1 + capacity) % capacity] : nil
    }

    /// The last `limit` levels, oldest first. Fewer when the history holds fewer.
    func recent(_ limit: Int) -> [Float] {
        let n = min(max(0, limit), count)
        guard n > 0 else { return [] }
        let start = (next - n + capacity * 2) % capacity
        return (0..<n).map { storage[(start + $0) % capacity] }
    }

    /// Every level held, oldest first.
    var levels: [Float] { recent(count) }

    /// A history that already holds `levels` (the newest `capacity` of them). For tests and previews.
    init(levels: [Float], capacity: Int = RecorderLevelMetrics.historyCapacity) {
        self.init(capacity: capacity)
        for level in levels { append(level) }
    }
}

/// Sizes of what the Bars and Wave styles draw, from a level history. Pure, so the mapping from
/// history to pixels is testable without a view.
enum LevelDisplayGeometry {
    /// One height per bar, oldest first, so the newest level is the last (trailing) bar. A history
    /// shorter than `barCount` leaves the leading bars at `minHeight`, which is how a recording
    /// that just started fills in from the trailing edge.
    static func barHeights(history: LevelHistory, barCount: Int, minHeight: CGFloat, maxHeight: CGFloat) -> [CGFloat] {
        guard barCount > 0 else { return [] }
        let levels = history.recent(barCount)
        let padding = Array(repeating: minHeight, count: barCount - levels.count)
        return padding + levels.map { minHeight + CGFloat($0) * (maxHeight - minHeight) }
    }

    /// One half-height per wave point, oldest first. The wave is mirrored around its centre line,
    /// so this is the distance from the centre to the edge of the shape. Never below `minHalfHeight`
    /// (a silent wave stays a thin line).
    static func waveHalfHeights(
        history: LevelHistory, pointCount: Int, minHalfHeight: CGFloat, maxHalfHeight: CGFloat
    ) -> [CGFloat] {
        guard pointCount > 0 else { return [] }
        let levels = history.recent(pointCount)
        let padding = Array(repeating: minHalfHeight, count: pointCount - levels.count)
        return padding + levels.map { minHalfHeight + CGFloat($0) * (maxHalfHeight - minHalfHeight) }
    }

    /// The single bar shown with Reduce Motion on: its filled fraction of the track, from the
    /// newest level. An empty history is an empty bar.
    static func meterFraction(history: LevelHistory) -> CGFloat {
        CGFloat(history.latest ?? 0)
    }
}
