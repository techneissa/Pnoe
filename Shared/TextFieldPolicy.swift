import AppKit

/// Keeps system popups, auto-substitution and stray focus out of text fields.
///
/// Password AutoFill (`SPRoundedWindow`), text completion and Writing Tools can each draw an empty
/// window under a field the first time it is focused. The AutoFill one only obeys user defaults;
/// the others obey properties on the field editor, which this applies at focus time.
@MainActor
enum TextFieldPolicy {
    private static var focusObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private static var notificationTokens: [NSObjectProtocol] = []
    private static var mouseMonitor: Any?

    /// Call from `applicationWillFinishLaunching`, before any window exists. The app domain
    /// wins over the user's global System Settings values; `register(defaults:)` would lose.
    static func installLaunchDefaults() {
        let keys = [
            "NSAutoFillHeuristicsEnabled",
            "NSAutomaticTextCompletionEnabled",
            "NSAutomaticInlinePredictionEnabled",
            "NSAutomaticSpellingCorrectionEnabled",
            "NSAutomaticQuoteSubstitutionEnabled",
            "NSAutomaticDashSubstitutionEnabled",
            "NSAutomaticTextReplacementEnabled",
            "NSAutomaticPeriodSubstitutionEnabled",
            "NSAutomaticCapitalizationEnabled",
        ]
        for key in keys {
            UserDefaults.standard.set(false, forKey: key)
        }
    }

    static func installObserver() {
        guard notificationTokens.isEmpty else { return }
        let center = NotificationCenter.default

        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            notificationTokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) { note in
                    guard let window = note.object as? NSWindow else { return }
                    MainActor.assumeIsolated { observeFocus(of: window) }
                })
        }
        notificationTokens.append(
            center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    focusObservations[ObjectIdentifier(window)] = nil
                }
            })
        // Fallback for windows that were never seen becoming key.
        notificationTokens.append(
            center.addObserver(forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main) { note in
                guard let textView = note.object as? NSTextView else { return }
                MainActor.assumeIsolated { apply(to: textView) }
            })

        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated { endEditingIfClickedAway(event) }
            return event
        }
    }

    private static func observeFocus(of window: NSWindow) {
        let id = ObjectIdentifier(window)
        if let textView = window.firstResponder as? NSTextView {
            apply(to: textView)
        }
        guard focusObservations[id] == nil else { return }
        focusObservations[id] = window.observe(\.firstResponder, options: [.new]) { _, change in
            guard let textView = change.newValue.flatMap({ $0 }) as? NSTextView else { return }
            MainActor.assumeIsolated { apply(to: textView) }
        }
    }

    static func apply(to textView: NSTextView) {
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.inlinePredictionType = .no
        textView.writingToolsBehavior = .none
    }

    /// A click outside the focused field ends editing, so the field editor lets go of focus.
    private static func endEditingIfClickedAway(_ event: NSEvent) {
        guard let window = event.window,
            clickEndsEditing(at: event.locationInWindow, in: window)
        else { return }
        window.makeFirstResponder(nil)
    }

    /// True when a field editor is active and the point, in window coordinates, lands on
    /// something other than that editor, a text field or a text view.
    static func clickEndsEditing(at windowPoint: NSPoint, in window: NSWindow) -> Bool {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
            let contentView = window.contentView
        else { return false }

        // `hitTest(_:)` takes a point in the receiver's superview coordinates.
        let point = contentView.superview?.convert(windowPoint, from: nil) ?? windowPoint
        var view = contentView.hitTest(point)
        while let current = view {
            if current === editor || current is NSTextField || current is NSText { return false }
            view = current.superview
        }
        return true
    }
}
