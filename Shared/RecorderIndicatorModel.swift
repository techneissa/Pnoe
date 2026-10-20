import AppKit
import Foundation

// Model and logic of the recording indicator: states, settings, display choice and the live
// transcript line. Plain values with no dependency on the rest of the app, so the unit tests
// compile this file directly.

enum RecordingState: Equatable {
    case idle
    case starting
    case recording
    case transcribing
    case enhancing
    /// The take was pasted: the recorder shows a check mark for a moment (`RecorderOutcomeFlow`).
    case done
    /// The take was cancelled or failed: the recorder shows the error symbol for a moment.
    case failed
    case busy
}

enum RecorderPanelStyle: String, CaseIterable, Identifiable {
    case mini
    case notch
    case pill
    case dot

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mini:
            return String(localized: "Mini")
        case .notch:
            return String(localized: "Notch")
        case .pill:
            return String(localized: "Pill")
        case .dot:
            return String(localized: "Dot")
        }
    }

    /// A stored value maps to its style; a missing or unknown one (an older or newer build wrote
    /// it) is Mini, which is what Pnoe showed by default before the other styles existed. The
    /// two values older builds wrote, `mini` and `notch`, keep their meaning.
    init(storedValue: String?) {
        self = storedValue.flatMap(RecorderPanelStyle.init(rawValue:)) ?? .mini
    }

    static var stored: RecorderPanelStyle {
        RecorderPanelStyle(storedValue: UserDefaults.standard.string(forKey: "RecorderType"))
    }

    /// Whether the style has a left and a right side that the slot settings fill.
    var hasSideSlots: Bool { self != .dot }

    /// Whether the style can show the live transcript line by itself. The dot cannot; while the
    /// assistant panel is open it shows the pill layout, which carries the panel.
    var showsLiveTranscript: Bool { self != .dot }
}

enum RecorderDisplaySettingsKeys {
    static let showLiveTranscript = "ShowLiveTranscript"
    static let liveTranscriptSize = "RecorderLiveTranscriptSize"
    static let theme = "RecorderTheme"
    static let levelDisplay = "RecorderLevelDisplay"
    static let display = "RecorderDisplay"
    static let miniPlacement = "RecorderMiniPlacement"
    static let visibility = "RecorderVisibility"
}

extension RecorderPanelStyle {
    /// The panel shows the Mini family (Mini, Pill, Dot) in `MiniRecorderPanel` and Notch in
    /// `NotchRecorderPanel`.
    var usesMiniPanel: Bool { self != .notch }
}

/// Settings for how the recording indicator looks and where it appears. Every value is stored
/// as a plain string in `UserDefaults`, so the views read them with `@AppStorage` and the
/// window code reads them through `RecorderIndicatorSettings.current`.

enum RecorderTheme: String, CaseIterable, Identifiable {
    case dark
    case translucent
    case light

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dark: return String(localized: "Dark")
        case .translucent: return String(localized: "Translucent")
        case .light: return String(localized: "Light")
        }
    }
}

enum LiveTranscriptSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    /// `medium` is the size the live text had before this setting existed.
    var fontSize: CGFloat {
        switch self {
        case .small: return 10.5
        case .medium: return 12
        case .large: return 14
        }
    }

    var displayName: String {
        switch self {
        case .small: return String(localized: "Small")
        case .medium: return String(localized: "Medium")
        case .large: return String(localized: "Large")
        }
    }
}

enum MiniRecorderPlacement: String, CaseIterable, Identifiable {
    case bottom
    case top

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bottom: return String(localized: "Bottom")
        case .top: return String(localized: "Top")
        }
    }
}

enum RecorderVisibility: String, CaseIterable, Identifiable {
    case whileRecording
    case always

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whileRecording: return String(localized: "While recording")
        case .always: return String(localized: "Always")
        }
    }
}

/// Which display the indicator appears on.
enum RecorderDisplaySelection: Equatable {
    /// The display of the window with keyboard focus (what Pnoe always used before).
    case active
    /// The display that carries the menu bar.
    case main
    /// A display picked by its name. Falls back to `.active` while it is disconnected.
    case named(String)

    private static let namedPrefix = "name:"

    init(storedValue: String?) {
        switch storedValue {
        case "main":
            self = .main
        case .some(let value) where value.hasPrefix(Self.namedPrefix) && value.count > Self.namedPrefix.count:
            self = .named(String(value.dropFirst(Self.namedPrefix.count)))
        default:
            self = .active
        }
    }

    var storedValue: String {
        switch self {
        case .active: return "active"
        case .main: return "main"
        case .named(let name): return Self.namedPrefix + name
        }
    }
}

struct RecorderIndicatorSettings: Equatable {
    var display: RecorderDisplaySelection
    var miniPlacement: MiniRecorderPlacement
    var visibility: RecorderVisibility
    /// What each style shows beside its controls. They decide how wide a panel's window is, so a
    /// change rebuilds the panel like the other values here.
    var sideSlots: [RecorderPanelStyle: RecorderSideSlots]

    static var current: RecorderIndicatorSettings {
        RecorderIndicatorSettings(defaults: .standard)
    }

    init(
        display: RecorderDisplaySelection = .active,
        miniPlacement: MiniRecorderPlacement = .bottom,
        visibility: RecorderVisibility = .whileRecording,
        sideSlots: [RecorderPanelStyle: RecorderSideSlots] = [:]
    ) {
        self.display = display
        self.miniPlacement = miniPlacement
        self.visibility = visibility
        // Styles not given keep their default slots, so two settings values compare equal
        // whether they came from the defaults or from an empty `UserDefaults`.
        self.sideSlots = RecorderPanelStyle.allCases.reduce(into: [:]) { result, style in
            result[style] = sideSlots[style] ?? .defaults(for: style)
        }
    }

    func slots(for style: RecorderPanelStyle) -> RecorderSideSlots {
        sideSlots[style] ?? .defaults(for: style)
    }

    init(defaults: UserDefaults) {
        display = RecorderDisplaySelection(storedValue: defaults.string(forKey: RecorderDisplaySettingsKeys.display))
        miniPlacement =
            defaults.string(forKey: RecorderDisplaySettingsKeys.miniPlacement)
            .flatMap(MiniRecorderPlacement.init(rawValue:)) ?? .bottom
        visibility =
            defaults.string(forKey: RecorderDisplaySettingsKeys.visibility)
            .flatMap(RecorderVisibility.init(rawValue:)) ?? .whileRecording
        sideSlots = Dictionary(
            uniqueKeysWithValues: RecorderPanelStyle.allCases.map { style in
                (style, RecorderSideSlots(defaults: defaults, style: style))
            })
    }
}

/// What the display choice needs to know about one screen. Plain values, so the choice can be
/// unit-tested without any real display.
struct RecorderDisplayInfo: Equatable {
    let id: Int
    let name: String
    let isBuiltIn: Bool
    let hasNotch: Bool
}

/// The display and style the indicator uses once the settings and the connected displays are
/// known. Pure logic: `RecorderScreenResolver` feeds it from `NSScreen`.
enum RecorderDisplayPlanner {
    /// Returns the id of the display to use, or `nil` when no display is connected.
    ///
    /// `.active` follows the display of the focused window, then the display under the mouse,
    /// then the first display. A named display that is not connected falls back the same way, so
    /// unplugging the chosen monitor never leaves the indicator without a place to appear.
    static func resolveDisplayID(
        selection: RecorderDisplaySelection,
        displays: [RecorderDisplayInfo],
        activeID: Int?,
        underMouseID: Int?
    ) -> Int? {
        guard !displays.isEmpty else { return nil }

        func activeFallback() -> Int? {
            if let activeID, displays.contains(where: { $0.id == activeID }) { return activeID }
            if let underMouseID, displays.contains(where: { $0.id == underMouseID }) { return underMouseID }
            return displays.first?.id
        }

        switch selection {
        case .active:
            return activeFallback()
        case .main:
            return displays.first?.id
        case .named(let name):
            return displays.first(where: { $0.name == name })?.id ?? activeFallback()
        }
    }

    /// The Notch style needs a notch to wrap around. A built-in display without one gets the
    /// Mini style instead; an external display keeps Notch, which then hangs from the top edge.
    static func effectiveStyle(requested: RecorderPanelStyle, display: RecorderDisplayInfo?) -> RecorderPanelStyle {
        guard requested == .notch, let display else { return requested }
        return display.isBuiltIn && !display.hasNotch ? .mini : .notch
    }

    /// The layout actually drawn. The dot has no room for the assistant panel, so while that
    /// panel is open the dot is replaced by the pill, which expands to carry it.
    static func layoutStyle(for style: RecorderPanelStyle, assistantVisible: Bool) -> RecorderPanelStyle {
        style == .dot && assistantVisible ? .pill : style
    }
}

/// What the live line shows for the current state, or nothing.
enum LiveTranscriptContent: Equatable {
    case text(String)
    /// Streaming engine, no words yet.
    case listening

    /// `expectsPartials` is true when the engine in use sends partial transcripts. An engine
    /// that does not gets no line at all: nothing would ever fill it.
    static func resolve(
        enabled: Bool,
        state: RecordingState,
        partial: String,
        expectsPartials: Bool
    ) -> LiveTranscriptContent? {
        guard enabled, state == .recording else { return nil }
        if !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .text(partial) }
        return expectsPartials ? .listening : nil
    }
}

enum LiveTranscriptMetrics {
    static let maxLines = 2

    static func lineHeight(for size: LiveTranscriptSize) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size.fontSize)
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// Height of the whole line area: two text lines plus padding, at least the 56 points the
    /// old scrolling box had. Fixed per size, so the recorder does not change height while
    /// words arrive.
    static func height(for size: LiveTranscriptSize) -> CGFloat {
        max(56, lineHeight(for: size) * CGFloat(maxLines) + 14)
    }
}

/// When a recorder panel may become the key window. The panels never activate the app, but a
/// key panel takes keyboard focus from the frontmost app, so only the assistant panel's
/// follow-up text field earns it. Buttons and dragging work on a panel that is not key.
enum RecorderKeyWindowPolicy {
    static func canBecomeKey(assistantVisible: Bool) -> Bool { assistantVisible }
}
