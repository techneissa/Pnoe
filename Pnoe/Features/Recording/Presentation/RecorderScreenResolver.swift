import AppKit

/// Resolves the screen the recorder panel should be placed on.
///
/// `NSScreen.main` is the screen containing the window with keyboard focus. Pnoe is a
/// menu-bar style app that usually has no key window, so `NSScreen.main` can return `nil` —
/// most plausibly while displays are asleep or being reconfigured.
///
/// The point of this helper is the fallback chain, not the nil case itself: callers must never
/// fall back to a rect at the global origin, because a transparent, shadowless panel placed at
/// (0, 0) sits behind the Dock and is indistinguishable from a panel that never appeared.
enum RecorderScreenResolver {
    static func resolve(settings: RecorderIndicatorSettings = .current) -> NSScreen? {
        let screens = NSScreen.screens
        let displays = screens.compactMap(displayInfo(for:))
        let mouseLocation = NSEvent.mouseLocation

        let id = RecorderDisplayPlanner.resolveDisplayID(
            selection: settings.display,
            displays: displays,
            activeID: NSScreen.main.flatMap(displayID(for:)),
            underMouseID: screens.first(where: { $0.frame.contains(mouseLocation) }).flatMap(displayID(for:))
        )

        if let id, let screen = screens.first(where: { displayID(for: $0) == id }) { return screen }
        return NSScreen.main ?? screens.first
    }

    /// The style to show: the requested one, unless the target display cannot carry it.
    static func effectiveStyle(
        requested: RecorderPanelStyle,
        settings: RecorderIndicatorSettings = .current
    ) -> RecorderPanelStyle {
        let display = resolve(settings: settings).flatMap(displayInfo(for:))
        return RecorderDisplayPlanner.effectiveStyle(requested: requested, display: display)
    }

    /// Names of the connected displays, for the picker.
    static var connectedDisplayNames: [String] {
        NSScreen.screens.map(\.localizedName)
    }

    static func displayInfo(for screen: NSScreen) -> RecorderDisplayInfo? {
        guard let id = displayID(for: screen) else { return nil }
        return RecorderDisplayInfo(
            id: id,
            name: screen.localizedName,
            isBuiltIn: CGDisplayIsBuiltin(CGDirectDisplayID(id)) != 0,
            hasNotch: screen.safeAreaInsets.top > 0
        )
    }

    private static func displayID(for screen: NSScreen) -> Int? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue
    }
}
