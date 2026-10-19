import CoreGraphics
import Foundation

// What the recording indicator shows on its left and right side, how wide that makes each
// panel, the recording timer, and the synthetic input the settings preview draws. Plain values
// with no dependency on the rest of the app, so the unit tests compile this file directly.

/// One thing a side slot can show.
enum RecorderSlotContent: String, CaseIterable, Identifiable {
    case none
    case timer
    case level
    case modeName

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return String(localized: "Nothing")
        case .timer: return String(localized: "Timer")
        case .level: return String(localized: "Level meter")
        case .modeName: return String(localized: "Mode name")
        }
    }

    /// Width the slot reserves in a bar. The level meter is 30 bars of 1.5 pt with 1 pt gaps.
    var width: CGFloat {
        switch self {
        case .none: return 0
        case .timer: return 36
        case .level: return RecorderLevelMetrics.meterWidth
        case .modeName: return 64
        }
    }
}

enum RecorderSlotSide {
    case left
    case right
}

/// The two side slots of one style. Stored as `"left,right"` of `RecorderSlotContent` raw
/// values, one key per style.
struct RecorderSideSlots: Equatable {
    var left: RecorderSlotContent
    var right: RecorderSlotContent

    /// The same thing on both sides would draw it twice, so the right side gives way.
    init(left: RecorderSlotContent, right: RecorderSlotContent) {
        self.left = left
        self.right = (right != .none && right == left) ? .none : right
    }

    /// What each style showed before the slots existed, so an existing user sees no change:
    /// Mini and Notch show the level meter on the right and nothing on the left. The pill is
    /// new and shows the timer and the level.
    static func defaults(for style: RecorderPanelStyle) -> RecorderSideSlots {
        switch style {
        case .mini, .notch: return RecorderSideSlots(left: .none, right: .level)
        case .pill: return RecorderSideSlots(left: .timer, right: .level)
        case .dot: return RecorderSideSlots(left: .none, right: .none)
        }
    }

    static func storageKey(for style: RecorderPanelStyle) -> String {
        "RecorderSideSlots.\(style.rawValue)"
    }

    var storedValue: String { "\(left.rawValue),\(right.rawValue)" }

    /// Reads a stored value. A missing value, a malformed one, or a side whose token is unknown
    /// (a newer build wrote it) takes that side's default for the style.
    init(storedValue: String?, style: RecorderPanelStyle) {
        let fallback = Self.defaults(for: style)
        let parts = (storedValue ?? "").split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else {
            self = fallback
            return
        }
        self.init(
            left: RecorderSlotContent(rawValue: parts[0]) ?? fallback.left,
            right: RecorderSlotContent(rawValue: parts[1]) ?? fallback.right)
    }

    init(defaults: UserDefaults, style: RecorderPanelStyle) {
        self.init(storedValue: defaults.string(forKey: Self.storageKey(for: style)), style: style)
    }

    func content(on side: RecorderSlotSide) -> RecorderSlotContent {
        side == .left ? left : right
    }

    /// Puts `content` on `side`. When the other side already shows it, that side takes what this
    /// side showed, so a picker never silently loses a choice: picking "Timer" on the left while
    /// the right shows the timer swaps the two.
    func setting(_ side: RecorderSlotSide, to newContent: RecorderSlotContent) -> RecorderSideSlots {
        let otherSide: RecorderSlotSide = side == .left ? .right : .left
        let other = content(on: otherSide)
        let newOther = (newContent != .none && other == newContent) ? content(on: side) : other
        switch side {
        case .left: return RecorderSideSlots(left: newContent, right: newOther)
        case .right: return RecorderSideSlots(left: newOther, right: newContent)
        }
    }

    /// Width of both slots side by side, with the gap between them when both are used.
    var contentWidth: CGFloat {
        left.width + right.width + (left != .none && right != .none ? RecorderBarMetrics.slotSpacing : 0)
    }
}

/// Widths of the bars, from their controls and their slots. The window code sizes the transparent
/// panel from these, and the layouts size their visible bar from the same numbers.
enum RecorderBarMetrics {
    static let slotSpacing: CGFloat = 10

    // Mini: record button (21) with 10 leading, mode button (22) with 12 trailing, and a gutter
    // of 8 each side of the slots.
    static let miniChrome: CGFloat = 10 + 21 + 12 + 22 + 16
    static let miniCompactWidth: CGFloat = 184
    static let miniExpandedWidth: CGFloat = 300

    // Pill: record button (21) with 10 leading and 12 trailing padding, 10 before the slots.
    static let pillHeight: CGFloat = 34
    static let pillMinWidth: CGFloat = 56

    static func miniBarWidth(slots: RecorderSideSlots) -> CGFloat {
        max(miniCompactWidth, miniChrome + slots.contentWidth)
    }

    static func miniExpandedBarWidth(slots: RecorderSideSlots) -> CGFloat {
        max(miniExpandedWidth, miniChrome + slots.contentWidth)
    }

    static func pillBarWidth(slots: RecorderSideSlots) -> CGFloat {
        let slotsWidth = slots.contentWidth
        return max(pillMinWidth, 10 + 21 + (slotsWidth > 0 ? 10 + slotsWidth : 0) + 12)
    }

    // Notch: the pill hangs from the camera housing and grows to both sides by the same amount.
    // The left side holds the record button (21), 14, the mode button (20), then the left slot;
    // the right side holds the right slot. Each has its edge padding.
    static let notchLeftControls: CGFloat = 21 + 14 + 20
    static let notchSlotSpacing: CGFloat = 14

    /// How far the notch pill reaches out on each side: at least `base`, more when a slot needs it.
    static func notchSideExpansion(base: CGFloat, edgePadding: CGFloat, slots: RecorderSideSlots) -> CGFloat {
        let left = edgePadding + notchLeftControls + (slots.left != .none ? notchSlotSpacing + slots.left.width : 0)
        let right = edgePadding + slots.right.width
        return max(base, left, right)
    }
}

/// The dot style's sizes and how the level moves it.
enum RecorderDotMetrics {
    static let diameter: CGFloat = 14
    /// Room around the dot for its halo, so the halo never changes the layout.
    static let areaSize: CGFloat = 30
    static let capsuleHeight: CGFloat = 32
    static let spacing: CGFloat = 2
    static let timerWidth: CGFloat = 34

    /// The halo behind the recording dot: the dot's size at silence, twice that at full level.
    static func haloScale(level: Float) -> CGFloat {
        1 + CGFloat(min(1, max(0, level)))
    }

    /// Width of the dot with its timer label (when `showsTimer`) inside the capsule.
    static func width(showsTimer: Bool) -> CGFloat {
        showsTimer ? 4 + areaSize + spacing + timerWidth + 10 : capsuleHeight
    }
}

/// Sizes of the transparent windows that carry the Mini, Pill and Dot layouts.
enum RecorderPanelSizing {
    static let miniHostSize = CGSize(width: 540, height: 430)
    static let dotHostSize = CGSize(width: 140, height: 44)

    /// `compact` is the idle indicator between dictations (visibility "Always"): only as large as
    /// the bar, so the window never covers other apps. A dot has no assistant panel, so it keeps
    /// its small window until the assistant opens and the pill layout takes over.
    static func miniHostSize(
        style: RecorderPanelStyle, compact: Bool, assistantVisible: Bool, slots: RecorderSideSlots
    ) -> CGSize {
        switch RecorderDisplayPlanner.layoutStyle(for: style, assistantVisible: assistantVisible) {
        case .dot:
            return dotHostSize
        case .pill:
            guard compact, !assistantVisible else { return miniHostSize }
            return CGSize(width: RecorderBarMetrics.pillBarWidth(slots: slots) + 16, height: 44)
        case .mini, .notch:
            guard compact else { return miniHostSize }
            return CGSize(width: max(200, RecorderBarMetrics.miniBarWidth(slots: slots) + 16), height: 48)
        }
    }

    /// Per-side reach of the notch window, wide enough for the slots.
    static func notchMaxSideExpansion(compact: Bool, slots: RecorderSideSlots) -> CGFloat {
        max(
            compact ? 100 : 240,
            RecorderBarMetrics.notchSideExpansion(base: 90, edgePadding: 16, slots: slots))
    }
}

/// The time shown by the timer slot and the dot's label. A value: the recorder owns one and the
/// views read a copy.
struct RecordingClock: Equatable {
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?

    init(startedAt: Date? = nil, endedAt: Date? = nil) {
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    mutating func start(at date: Date) {
        startedAt = date
        endedAt = nil
    }

    /// Freezes the time at the moment recording stopped, so the processing states keep showing
    /// the length of the take. Does nothing when no recording was started.
    mutating func stop(at date: Date) {
        guard startedAt != nil, endedAt == nil else { return }
        endedAt = date
    }

    func elapsed(at now: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    /// "0:07", "12:03", "1:02:03".
    static func format(_ elapsed: TimeInterval) -> String {
        let total = Int(max(0, elapsed.isFinite ? elapsed : 0))
        let seconds = total % 60
        let minutes = (total / 60) % 60
        let hours = total / 3600
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", total / 60, seconds)
    }

    /// A clock that counts up and starts over every `period` seconds, for the settings preview.
    static func looping(period: TimeInterval, at now: Date) -> RecordingClock {
        let seconds = now.timeIntervalSinceReferenceDate
        let start = seconds - seconds.truncatingRemainder(dividingBy: period)
        return RecordingClock(startedAt: Date(timeIntervalSinceReferenceDate: start))
    }
}

/// A speech-like input level that depends only on the time, for the settings preview and its
/// renders: phrases of about two seconds with pauses between, syllables at about three a second,
/// a slow swell over each phrase, and room noise in the pauses.
enum SyntheticLevels {
    private static let phrasePeriod = 3.4
    private static let phraseLength = 2.4

    static func level(at time: TimeInterval) -> Float {
        let phase = time - (time / phrasePeriod).rounded(.down) * phrasePeriod
        guard phase < phraseLength else {
            return 0.03 + 0.02 * Float(abs(sin(time * 9.7)))
        }
        let syllable = pow(abs(sin(Double.pi * time / 0.34)), 1.4)
        let swell = 0.55 + 0.45 * sin(Double.pi * phase / phraseLength)
        return Float(min(1, max(0, 0.06 + 0.94 * syllable * swell)))
    }

    /// The history a recorder would hold at `time`: the last two seconds at 30 samples a second,
    /// through the same fast-attack, slow-release smoothing the recorder uses.
    static func history(endingAt time: TimeInterval) -> LevelHistory {
        let capacity = RecorderLevelMetrics.historyCapacity
        let step = 1 / RecorderLevelMetrics.samplesPerSecond
        let warmUp = 30
        var history = LevelHistory()
        var smoothed: Float = 0
        for index in -warmUp..<capacity {
            let sampleTime = time - Double(capacity - 1 - index) * step
            smoothed = LevelMapping.smoothed(previous: smoothed, next: level(at: sampleTime))
            if index >= 0 { history.append(smoothed) }
        }
        return history
    }
}
