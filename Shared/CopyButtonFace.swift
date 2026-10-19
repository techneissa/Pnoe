import SwiftUI

/// The face of a copy button: the copy symbol that turns into a check mark when the value is copied
/// (the app flips `copied` back after `Motion.copiedHold`). Takes plain colors, so the design-system
/// button that owns the action and a test that renders the copied state both use it.
struct CopyButtonFace: View {
    let copied: Bool
    var idle: String = "doc.on.doc"
    var idleColor: Color = .primary
    var copiedColor: Color = .green
    var fill: Color = Color(nsColor: .windowBackgroundColor).opacity(0.92)
    var border: Color = Color.primary.opacity(0.12)
    var cornerRadius: CGFloat = 8

    var body: some View {
        Image(systemName: Motion.copySymbol(copied: copied, idle: idle))
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(copied ? copiedColor : idleColor)
            .motionSymbolReplace(value: copied)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(border, lineWidth: 1)
                    }
            )
    }
}
