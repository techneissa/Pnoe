import AppKit
import os

final class MiniRecorderPanel: NSPanel {
    /// Set while the assistant panel's text field needs the keyboard; see `RecorderKeyWindowPolicy`.
    var acceptsKeyboardInput = false
    override var canBecomeKey: Bool { acceptsKeyboardInput }

    private let logger = Logger(subsystem: "com.techneissa.pnoe", category: "MiniRecorderPanel")

    init(contentRect: NSRect) {
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
    /// large as the control bar, so the transparent host never covers other apps' content.
    static func calculateWindowMetrics(
        compact: Bool = false,
        settings: RecorderIndicatorSettings = .current
    ) -> NSRect? {
        // Host stays large enough for assistant output; SwiftUI controls the visible mini width.
        let width: CGFloat = compact ? 200 : 540
        let height: CGFloat = compact ? 48 : 430

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
        guard let metrics = MiniRecorderPanel.calculateWindowMetrics(compact: compact) else {
            logger.error("Mini panel show skipped: no screen available")
            return false
        }

        setFrame(metrics, display: true)
        orderFrontRegardless()

        logger.notice(
            "Mini panel frame=\(NSStringFromRect(self.frame), privacy: .public) screens=\(NSScreen.screens.count, privacy: .public) onActiveSpace=\(self.isOnActiveSpace, privacy: .public)"
        )
        return true
    }

    deinit {
        logger.debug("Mini panel deallocated")
    }
}
