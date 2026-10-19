import SwiftUI

struct CopyIconButton: View {
    let textToCopy: String
    var accessibilityLabel: LocalizedStringResource = "Copy"
    @StateObject private var hold = MotionHold()

    private var copied: Bool { hold.isHeld }

    var body: some View {
        Button(action: copy) {
            CopyButtonFace(
                copied: copied,
                idleColor: AppTheme.Selection.foreground,
                copiedColor: AppTheme.Status.positive,
                fill: AppTheme.Surface.window.opacity(0.92),
                border: AppTheme.Border.card,
                cornerRadius: AppTheme.Radius.control)
        }
        .focusEffectDisabled()
        .buttonStyle(.plain)
        .motionHover(cornerRadius: AppTheme.Radius.control)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .onDisappear { hold.cancel() }
    }

    private func copy() {
        let _ = ClipboardManager.copyToClipboard(textToCopy)
        hold.hold()
    }
}

extension View {
    func hoverCopyButton(
        textToCopy: String,
        accessibilityLabel: LocalizedStringResource = "Copy",
        alignment: Alignment = .bottomTrailing,
        padding: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 8)
    ) -> some View {
        modifier(
            HoverCopyButtonModifier(
                textToCopy: textToCopy,
                accessibilityLabel: accessibilityLabel,
                alignment: alignment,
                padding: padding
            )
        )
    }
}

private struct HoverCopyButtonModifier: ViewModifier {
    let textToCopy: String
    let accessibilityLabel: LocalizedStringResource
    let alignment: Alignment
    let padding: EdgeInsets

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: alignment) {
                if isHovering {
                    CopyIconButton(textToCopy: textToCopy, accessibilityLabel: accessibilityLabel)
                        .padding(padding)
                        .motionFade()
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                Motion.animate(.hover) {
                    isHovering = hovering
                }
            }
            .onDisappear { isHovering = false }
    }
}
