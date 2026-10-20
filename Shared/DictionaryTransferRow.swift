import SwiftUI

/// "Export Dictionary" / "Import Dictionary": the remembered folder or file (once there is one) with a
/// Change… button, and the button that does the job without asking where.
struct DictionaryTransferRow: View {
    let title: LocalizedStringKey
    let actionTitle: LocalizedStringKey
    /// The name of the remembered folder or file; `nil` until the user chose one.
    let rememberedName: String?
    let change: () -> Void
    let action: () -> Void

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                if let rememberedName {
                    Text(rememberedName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Change…", action: change)
                }
                Button(actionTitle, action: action)
            }
        }
        .focusEffectDisabled()
    }
}
