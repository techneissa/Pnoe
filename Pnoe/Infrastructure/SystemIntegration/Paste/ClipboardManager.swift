import AppKit
import SwiftUI

struct ClipboardManager {
    static let pasteSessionType = PasteClipboard.pasteSessionType

    enum ClipboardError: Error {
        case copyFailed
        case accessDenied
    }

    static func setClipboard(_ text: String, transient: Bool = false, sessionID: String? = nil) -> Bool {
        PasteClipboard.write(text, transient: transient, sessionID: sessionID, on: .general)
    }

    static func copyToClipboard(_ text: String) -> Bool {
        return setClipboard(text, transient: false)
    }

    static func getClipboardContent() -> String? {
        return NSPasteboard.general.string(forType: .string)
    }
}

struct ClipboardMessageModifier: ViewModifier {
    @Binding var message: String

    func body(content: Content) -> some View {
        content
            .overlay(
                Group {
                    if !message.isEmpty {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(AppTheme.Status.positive)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(AppTheme.Status.positive.opacity(0.10))
                            .cornerRadius(4)
                            .motionFade()
                            .motion(.reveal, value: message)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding()
            )
    }
}

extension View {
    func clipboardMessage(_ message: Binding<String>) -> some View {
        self.modifier(ClipboardMessageModifier(message: message))
    }
}
