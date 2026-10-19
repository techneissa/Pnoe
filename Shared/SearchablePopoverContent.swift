import SwiftUI

/// The words of a search: every word must appear somewhere in the text of an item, in any case.
enum SearchWords {
    static func matches(_ text: String, query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return true }
        let haystack = text.lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }
}

/// A popover list with a search field at the top, focused when it opens, and the matching items below. Typing
/// filters, the arrow keys move the highlight, Return or a click picks, Escape closes. The model picker in the
/// Workflow editor and the Playground's model menu both use it; each supplies its own row.
struct SearchablePopoverContent<Item: Identifiable, Row: View>: View where Item.ID == String {
    let items: [Item]
    let selectedID: String?
    let searchText: (Item) -> String
    /// Shown instead of "No models match" when there is nothing to search at all.
    let emptyText: LocalizedStringKey?
    let onSelect: (Item) -> Void
    let onClose: () -> Void
    @ViewBuilder let row: (Item, _ isSelected: Bool) -> Row
    @State private var query: String
    @State private var highlighted: String?
    @State private var isShown: Bool
    @FocusState private var searchFocused: Bool

    init(
        items: [Item], selectedID: String?, initialQuery: String = "",
        searchText: @escaping (Item) -> String, emptyText: LocalizedStringKey? = nil,
        onSelect: @escaping (Item) -> Void, onClose: @escaping () -> Void,
        startsShown: Bool = false,
        @ViewBuilder row: @escaping (Item, _ isSelected: Bool) -> Row
    ) {
        self.items = items
        self.selectedID = selectedID
        self.searchText = searchText
        self.emptyText = emptyText
        self.onSelect = onSelect
        self.onClose = onClose
        self.row = row
        _query = State(initialValue: initialQuery)
        // The popover fades in with a small move when it opens; an offscreen render starts shown.
        _isShown = State(initialValue: startsShown)
    }

    private var matches: [Item] { items.filter { SearchWords.matches(searchText($0), query: query) } }

    private var current: Item? { matches.first { $0.id == highlighted } ?? matches.first }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let current { onSelect(current) } }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            if matches.isEmpty {
                Group {
                    if items.isEmpty, let emptyText {
                        Text(emptyText)
                    } else {
                        Text("No matches for “\(query)”")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 64)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(matches) { item in
                            Button { onSelect(item) } label: {
                                row(item, item.id == selectedID)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(item.id == current?.id ? Color.accentColor.opacity(0.14) : .clear))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .motionHover(cornerRadius: 6)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 400)
        .opacity(isShown ? 1 : 0)
        .offset(y: isShown ? 0 : -4)
        .motion(.panel, value: isShown)
        .motion(.hover, value: current?.id)
        .onAppear {
            searchFocused = true
            isShown = true
        }
        .onKeyPress(.downArrow) { move(by: 1) }
        .onKeyPress(.upArrow) { move(by: -1) }
        .onExitCommand(perform: onClose)
        .onChange(of: query) { _, _ in highlighted = nil }
    }

    private func move(by step: Int) -> KeyPress.Result {
        guard let index = matches.firstIndex(where: { $0.id == current?.id }) else { return .ignored }
        let next = min(max(index + step, 0), matches.count - 1)
        highlighted = matches[next].id
        return .handled
    }
}
