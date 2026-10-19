import SwiftUI

/// What the Snippets list needs to draw one row.
struct SnippetRowModel: Identifiable, Equatable {
    let id: UUID
    let trigger: String
    let expansion: String
}

/// The Snippets section of the Dictionary screen: an add button and the list of saved snippets.
/// It holds no data of its own, so the app feeds it from SwiftData and a test can render it offscreen.
struct SnippetsSectionView: View {
    let rows: [SnippetRowModel]
    let onAdd: () -> Void
    let onEdit: (SnippetRowModel) -> Void
    let onDelete: (SnippetRowModel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Say a trigger phrase to insert its saved text.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onAdd) {
                    Label("Add Snippet", systemImage: "plus.circle.fill")
                        .font(.system(size: 13))
                }
                .buttonStyle(.borderless)
                .help("Add snippet")
            }

            if rows.isEmpty {
                Text("No snippets yet. Add one, such as “my email” for your address.")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("Trigger")
                            .frame(width: 180, alignment: .leading)
                        Text("Inserted text")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 8)

                    Divider()

                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            SnippetRow(row: row, onEdit: { onEdit(row) }, onDelete: { onDelete(row) })
                            if row.id != rows.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SnippetRow: View {
    let row: SnippetRowModel
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(row.trigger)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .frame(width: 180, alignment: .leading)

            Text(row.expansion)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(row.expansion)

            HStack(spacing: 6) {
                Button(action: onEdit) {
                    Image(systemName: "pencil.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.borderless)
                .help("Edit snippet")
                .accessibilityLabel("Edit snippet \(row.trigger)")

                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.borderless)
                .help("Remove snippet")
                .accessibilityLabel("Remove snippet \(row.trigger)")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }
}
