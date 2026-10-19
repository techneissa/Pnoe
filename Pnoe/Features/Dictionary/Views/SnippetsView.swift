import SwiftData
import SwiftUI

struct SnippetsView: View {
    @Query(sort: \Snippet.trigger) private var snippets: [Snippet]
    @Environment(\.modelContext) private var modelContext
    @State private var sheet: SnippetSheet?
    @State private var alertMessage = ""
    @State private var showAlert = false

    private enum SnippetSheet: Identifiable {
        case add
        case edit(Snippet)

        var id: String {
            switch self {
            case .add: "add"
            case .edit(let snippet): snippet.id.uuidString
            }
        }
    }

    private var rows: [SnippetRowModel] {
        snippets
            .sorted { $0.trigger.localizedCaseInsensitiveCompare($1.trigger) == .orderedAscending }
            .map { SnippetRowModel(id: $0.id, trigger: $0.trigger, expansion: $0.expansion) }
    }

    var body: some View {
        SnippetsSectionView(
            rows: rows,
            onAdd: { sheet = .add },
            onEdit: { row in
                if let snippet = snippets.first(where: { $0.id == row.id }) { sheet = .edit(snippet) }
            },
            onDelete: { row in
                if let snippet = snippets.first(where: { $0.id == row.id }),
                    let error = SnippetService.remove(snippet, context: modelContext)
                {
                    alertMessage = error
                    showAlert = true
                }
            }
        )
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .add:
                EditSnippetSheet(snippet: nil, existing: snippets, modelContext: modelContext)
            case .edit(let snippet):
                EditSnippetSheet(snippet: snippet, existing: snippets, modelContext: modelContext)
            }
        }
        .alert("Snippet", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }
}
