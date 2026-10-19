import AppKit
import os

final class MiniRecorderPanel: NSPanel {
    /// Set while the assistant panel's text field needs the keyboard; see `RecorderKeyWindowPolicy`.
    var acceptsKeyboardInput = false
    override var canBecomeKey: Bool { acceptsKeyboardInput }

    private let logger = Logger(subsystem: "com.techneissa.pnoe", category: "MiniRecorderPanel")

    /// Mini, Pill and Dot all use this panel.
    let style: RecorderPanelStyle
    private var isCompact = false
    private var assistantVisible = false

    init(style: RecorderPanelStyle, contentRect: NSRect) {
        self.style = style
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configurePanel()
    }

    private func configurePanel() {
        isFloatingPanel = true
        canHide = false
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovable = true
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
    }

    /// Returns `nil` when there is no screen at all, so callers can skip showing the panel
    /// instead of placing it at the global origin.
    ///
    /// `compact` is the idle indicator that stays on screen between dictations: it is only as
    /// large as the bar, so the transparent host never covers other apps' content. The sizes
    /// come from `RecorderPanelSizing`.
    static func calculateWindowMetrics(
        style: RecorderPanelStyle = .mini,
        compact: Bool = false,
        assistantVisible: Bool = false,
        settings: RecorderIndicatorSettings = .current
    ) -> NSRect? {
        // The host stays large enough for assistant output (a dot stays small until the
        // assistant opens); SwiftUI controls the visible width.
        let size = RecorderPanelSizing.miniHostSize(
            style: style, compact: compact, assistantVisible: assistantVisible,
            slots: settings.slots(for: style == .dot ? .pill : style))
        let width = size.width
        let height = size.height

        guard let screen = RecorderScreenResolver.resolve(settings: settings) else { return nil }

        let padding: CGFloat = 24

        let visibleFrame = screen.visibleFrame
        let centerX = visibleFrame.midX
        let xPosition = centerX - (width / 2)
        let yPosition =
            settings.miniPlacement == .top
            ? visibleFrame.maxY - height - padding
            : visibleFrame.minY + padding

        return NSRect(
            x: xPosition,
            y: yPosition,
            width: width,
            height: height
        )
    }

    @discardableResult
    func show(compact: Bool = false) -> Bool {
        isCompact = compact
        guard let metrics = frameForCurrentState() else {
            logger.error("Mini panel show skipped: no screen available")
            return false
        }

        setFrame(metrics, display: true)
        orderFrontRegardless()

        logger.notice(
            "Mini panel style=\(self.style.rawValue, privacy: .public) frame=\(NSStringFromRect(self.frame), privacy: .public) screens=\(NSScreen.screens.count, privacy: .public) onActiveSpace=\(self.isOnActiveSpace, privacy: .public)"
        )
        return true
    }

    /// The dot's window is small until the assistant panel opens and grows with it. The other
    /// styles keep one size, so this only moves a panel that is on screen.
    func assistantVisibilityChanged(_ visible: Bool) {
        guard visible != assistantVisible else { return }
        assistantVisible = visible
        guard style == .dot, isVisible, let metrics = frameForCurrentState() else { return }
        setFrame(metrics, display: true)
    }

    private func frameForCurrentState() -> NSRect? {
        MiniRecorderPanel.calculateWindowMetrics(
            style: style, compact: isCompact, assistantVisible: assistantVisible)
    }

    deinit {
        logger.debug("Mini panel deallocated")
    }
}
