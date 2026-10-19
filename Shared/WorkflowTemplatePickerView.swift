import SwiftUI

/// What the template picker needs to draw one card.
struct WorkflowTemplateOption: Identifiable, Equatable {
    let id: UUID
    let title: String
    /// An SF Symbol name, or an emoji when `isEmoji` is set.
    let icon: String
    var isEmoji = false
    let summary: String
    var detail: String?
}

/// Compact template list for a new workflow: icon and title on one row, the explanation behind an
/// (i) popover. It holds no data of its own, so the app feeds it from the starter templates and a
/// test can render it offscreen.
struct WorkflowTemplatePickerView: View {
    let options: [WorkflowTemplateOption]
    /// `nil` starts a blank workflow.
    let onSelect: (WorkflowTemplateOption?) -> Void
    let onDismiss: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    WorkflowTemplateCard(
                        icon: "plus",
                        isEmoji: false,
                        title: "Blank",
                        summary: "Start from scratch and choose every setting yourself.",
                        detail: nil,
                        action: { onSelect(nil) }
                    )

                    ForEach(options) { option in
                        WorkflowTemplateCard(
                            icon: option.icon,
                            isEmoji: option.isEmoji,
                            title: option.title,
                            summary: option.summary,
                            detail: option.detail,
                            action: { onSelect(option) }
                        )
                    }
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onExitCommand(perform: onDismiss)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("New Workflow")
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(6)
                    .background(Color.secondary.opacity(0.10))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close")
            .accessibilityLabel("Close")
        }
        .focusEffectDisabled()
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }
}

private struct WorkflowTemplateCard: View {
    let icon: String
    let isEmoji: Bool
    let title: String
    let summary: String
    let detail: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 8) {
                    iconView
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )

                    Text(LocalizedStringKey(title))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            InfoTip(
                LocalizedStringKey(summary),
                detail: detail.map { LocalizedStringKey($0) },
                accessibilityLabel: "About \(title)"
            )
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.28), lineWidth: 1)
                )
        )
    }

    @ViewBuilder private var iconView: some View {
        if isEmoji {
            Text(icon).font(.system(size: 15))
        } else {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
    }
}
