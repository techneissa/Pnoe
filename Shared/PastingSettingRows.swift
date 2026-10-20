import SwiftUI

/// The clipboard rows of Settings › Pasting: what happens to the clipboard after Pnoe pastes, how long it waits
/// before putting the earlier item back, and whether clipboard history apps may record the dictated text. Lives apart
/// from the settings screen so it can be rendered on its own.
struct PastingSettingRows: View {
    /// On: put back what was copied before. Off: the dictated text stays on the clipboard.
    @Binding var restoreClipboard: Bool
    @Binding var restoreDelay: Double
    @Binding var addToHistory: Bool

    var body: some View {
        Group {
            HStack(spacing: 4) {
                Picker(selection: $restoreClipboard) {
                    Text("Keep the dictated text on the clipboard").tag(false)
                    Text("Put back what I copied before").tag(true)
                } label: {
                    Text("After pasting")
                }
                InfoTip(
                    "Default and AppleScript paste through the clipboard. The first choice leaves the dictated text there. The second puts back what you copied before, after the delay below. Direct Typing leaves the clipboard unchanged.",
                    detail: "Add dictated text to clipboard history lets history apps such as Maccy, Raycast or Paste record the dictation before your earlier item comes back. A history app that checks the clipboard less often than the delay may miss it; a longer delay helps. A short delay (500ms by default) keeps pasting fast.",
                    accessibilityLabel: "More information"
                )
            }

            if restoreClipboard {
                Picker("Restore Delay", selection: $restoreDelay) {
                    ForEach(ClipboardPasteSettings.restoreDelayOptions, id: \.self) { delay in
                        Text(Self.title(for: delay)).tag(delay)
                    }
                }
                .motionFade()

                Toggle("Add dictated text to clipboard history", isOn: $addToHistory)
                    .motionFade()
            }
        }
        .motion(.reveal, value: restoreClipboard)
    }

    static func title(for delay: Double) -> LocalizedStringKey {
        switch delay {
        case 0.25: return "250ms"
        case 0.5: return "500ms (default)"
        case 1: return "1s"
        case 2: return "2s"
        case 3: return "3s"
        case 4: return "4s"
        case 5: return "5s"
        default: return "\(delay)s"
        }
    }
}
