import AppKit
import Combine
import FormatterModels
import SwiftUI
import UniformTypeIdentifiers

/// One installed model in the picker.
struct BuiltInModelRow: Identifiable, Equatable {
    let id: String
    /// The name without the quantization, which has a badge of its own.
    let name: String
    let quantization: String?
    /// "3.1 GB", nil when the size is unknown.
    let sizeText: String?
    let source: FormatterModelSource

    init(entry: FormatterModelEntry) {
        id = entry.id
        name = BuiltInModels.title(of: entry)
        quantization = entry.quantization
        sizeText = entry.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        source = entry.source
    }

    init(id: String, name: String, quantization: String?, sizeText: String?, source: FormatterModelSource) {
        self.id = id
        self.name = name
        self.quantization = quantization
        self.sizeText = sizeText
        self.source = source
    }

    var sourceLabel: String { BuiltInModels.sourceLabel(source) }
}

/// What the search field matches: the name, the quantization and the source, every word of the query.
enum BuiltInModelSearch {
    static func filter(_ rows: [BuiltInModelRow], query: String) -> [BuiltInModelRow] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return rows }
        return rows.filter { row in
            let haystack = [row.name, row.quantization ?? "", row.sourceLabel].joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}

/// Symbols and system colours for the sources and the quantizations.
enum BuiltInModelStyle {
    static func symbol(for source: FormatterModelSource) -> String {
        switch source {
        case .huggingFaceCache: "face.smiling"
        case .lmStudio: "macwindow"
        case .ollama, .ollamaStore: "server.rack"
        case .userChosen: "doc"
        case .downloaded: "arrow.down.circle.fill"
        }
    }

    static func tint(for source: FormatterModelSource) -> Color {
        switch source {
        case .huggingFaceCache: .orange
        case .lmStudio: .purple
        case .ollama, .ollamaStore: .blue
        case .userChosen: .gray
        case .downloaded: .green
        }
    }

    /// Smaller bit widths are lighter and rougher, the 8-bit and 16-bit files are the closest to the original.
    static func tint(forQuantization quantization: String) -> Color {
        let upper = quantization.uppercased()
        if upper.hasPrefix("IQ") { return .purple }
        if upper.hasPrefix("Q2") || upper.hasPrefix("Q3") { return .orange }
        if upper.hasPrefix("Q4") { return .blue }
        if upper.hasPrefix("Q5") || upper.hasPrefix("Q6") { return .teal }
        return .green
    }
}

struct BuiltInQuantizationBadge: View {
    let quantization: String

    var body: some View {
        let tint = BuiltInModelStyle.tint(forQuantization: quantization)
        Text(quantization)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.15), in: Capsule())
            .fixedSize()
    }
}

/// A model as two lines: the name and its quantization badge, then the size and the source, each with a symbol.
struct BuiltInModelRowLabel: View {
    let row: BuiltInModelRow
    var isSelected = false
    var showsCheckmark = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(row.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let quantization = row.quantization {
                    BuiltInQuantizationBadge(quantization: quantization)
                }
                if showsCheckmark, isSelected {
                    Spacer(minLength: 4)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            HStack(spacing: 10) {
                if let size = row.sizeText {
                    HStack(spacing: 3) {
                        Image(systemName: "internaldrive")
                        Text(size)
                    }
                }
                HStack(spacing: 3) {
                    Image(systemName: BuiltInModelStyle.symbol(for: row.source))
                        .foregroundStyle(BuiltInModelStyle.tint(for: row.source))
                    Text(row.sourceLabel)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

/// The popover's content: a search field at the top (focused when it opens) and the matching models below.
/// Typing filters, the arrow keys move, Return or a click picks, Escape closes.
struct BuiltInModelPopoverContent: View {
    let rows: [BuiltInModelRow]
    let selectedID: String?
    let onSelect: (BuiltInModelRow) -> Void
    let onClose: () -> Void
    @State private var query: String
    @State private var highlighted: String?
    @FocusState private var searchFocused: Bool

    init(
        rows: [BuiltInModelRow], selectedID: String?, initialQuery: String = "",
        onSelect: @escaping (BuiltInModelRow) -> Void, onClose: @escaping () -> Void
    ) {
        self.rows = rows
        self.selectedID = selectedID
        self.onSelect = onSelect
        self.onClose = onClose
        _query = State(initialValue: initialQuery)
    }

    private var matches: [BuiltInModelRow] { BuiltInModelSearch.filter(rows, query: query) }

    private var current: BuiltInModelRow? {
        matches.first { $0.id == highlighted } ?? matches.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search models", text: $query)
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
                Text(rows.isEmpty ? "No models found" : "No models match “\(query)”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(matches) { row in
                            Button { onSelect(row) } label: {
                                BuiltInModelRowLabel(row: row, isSelected: row.id == selectedID, showsCheckmark: true)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(row.id == current?.id ? Color.accentColor.opacity(0.14) : .clear))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { inside in if inside { highlighted = row.id } }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 400)
        .onAppear { searchFocused = true }
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

/// The picker's closed state: the selected model in its two-line layout, and the popover it opens.
struct BuiltInModelPicker: View {
    let rows: [BuiltInModelRow]
    @Binding var selection: String?
    let isLoading: Bool
    @State private var isOpen = false

    private var selectedRow: BuiltInModelRow? { rows.first { $0.id == selection } }

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 8) {
                Group {
                    if let selectedRow {
                        BuiltInModelRowLabel(row: selectedRow)
                    } else if selection != nil {
                        Text("Model not found").foregroundStyle(.orange)
                    } else {
                        Text(isLoading ? "Looking for models…" : (rows.isEmpty ? "No models found" : "Choose a model"))
                            .foregroundStyle(.secondary)
                    }
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            BuiltInModelPopoverContent(
                rows: rows, selectedID: selection,
                onSelect: { row in
                    selection = row.id
                    isOpen = false
                },
                onClose: { isOpen = false })
        }
    }
}

/// The optional download of Gemma 4 E2B, for a Mac with nothing installed.
struct BuiltInDownloadRowState: Equatable {
    let name: String
    /// "3.1 GB", shown before anything is fetched.
    let sizeText: String
    let licenseName: String
    let state: FormatterModelDownloadState
}

/// When the download row is shown: nothing found on the Mac yet, or a download that is running, paused,
/// failed or done and not listed yet.
enum BuiltInDownloadVisibility {
    static func isVisible(installedCount: Int, state: FormatterModelDownloadState) -> Bool {
        switch state {
        case .notInstalled: installedCount == 0
        case .downloading, .paused, .verifying, .failed: true
        case .ready: false
        }
    }
}

/// The Built-in engine's rows in the Workflow editor, after "AI Provider": the model picker fed by installed
/// models, "Choose file…", and the optional download. It holds no state of its own so it can be rendered
/// with sample rows; `BuiltInEngineSection` wires it to the real list and store.
struct BuiltInEngineSectionContent: View {
    let rows: [BuiltInModelRow]
    @Binding var selection: String?
    let isLoading: Bool
    let download: BuiltInDownloadRowState?
    let onChooseFile: () -> Void
    let onDownload: () -> Void
    let onCancelDownload: () -> Void
    let onRemoveDownload: () -> Void

    var body: some View {
        LabeledContent("AI Model") {
            BuiltInModelPicker(rows: rows, selection: $selection, isLoading: isLoading)
        }

        LabeledContent("Model file") {
            Button("Choose file…", action: onChooseFile)
                .focusEffectDisabled()
        }

        if let download {
            BuiltInDownloadRow(
                download: download, onDownload: onDownload, onCancel: onCancelDownload, onRemove: onRemoveDownload)
        }

        Text("Runs on this Mac in its own process. Your words are not sent anywhere.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

struct BuiltInDownloadRow: View {
    let download: BuiltInDownloadRowState
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(download.name)
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(isFailure ? Color.red : Color.secondary)
                    .lineLimit(2)
                if let fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            action
        }
        .focusEffectDisabled()
    }

    private var isFailure: Bool {
        if case .failed = download.state { true } else { false }
    }

    private var fraction: Double? {
        if case .downloading(let fraction) = download.state { fraction } else { nil }
    }

    private var statusText: String {
        switch download.state {
        case .notInstalled:
            String(localized: "Optional download · \(download.sizeText) · \(download.licenseName)")
        case .downloading(let fraction):
            String(localized: "Downloading \(Int((fraction * 100).rounded()))% of \(download.sizeText)")
        case .paused:
            String(localized: "Paused until the network is back")
        case .verifying:
            String(localized: "Checking the download…")
        case .ready:
            String(localized: "Downloaded · \(download.sizeText)")
        case .failed(let message):
            message
        }
    }

    @ViewBuilder
    private var action: some View {
        switch download.state {
        case .notInstalled:
            Button("Download", action: onDownload)
        case .downloading, .paused:
            Button("Cancel", action: onCancel)
        case .verifying:
            ProgressView().controlSize(.small)
        case .ready:
            Button("Remove", role: .destructive, action: onRemove)
        case .failed:
            Button("Try Again", action: onDownload)
        }
    }
}

/// The list of installed models and the download store behind the section. One instance for the app, so a
/// download goes on when the editor closes.
@MainActor
final class BuiltInModelsModel: ObservableObject {
    static let shared = BuiltInModelsModel()

    @Published private(set) var entries: [FormatterModelEntry] = []
    @Published private(set) var isLoading = false
    let store: FormatterModelStore
    private var storeObserver: AnyCancellable?
    private var lastState: FormatterModelDownloadState

    init(store: FormatterModelStore? = nil) {
        let store = store ?? FormatterModelStore()
        self.store = store
        lastState = store.state
        storeObserver = store.objectWillChange.sink { [weak self] _ in
            // `objectWillChange` fires before the value changes; look at the state on the next turn.
            Task { @MainActor [weak self] in self?.storeChanged() }
        }
        store.onModelDeleted = { [weak self] in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    var rows: [BuiltInModelRow] { entries.map(BuiltInModelRow.init(entry:)) }

    var download: BuiltInDownloadRowState? {
        let installed = entries.filter { $0.source != .downloaded }.count
        guard BuiltInDownloadVisibility.isVisible(installedCount: installed, state: store.state) else { return nil }
        return BuiltInDownloadRowState(
            name: store.artifact.displayName,
            sizeText: store.artifact.downloadSizeText,
            licenseName: store.artifact.licenseName,
            state: store.state)
    }

    func refresh() async {
        isLoading = true
        entries = await BuiltInModels.installed(chosenFiles: BuiltInEngine.storedChosenFiles(), artifact: store.artifact)
        isLoading = false
    }

    func addChosenFile(_ url: URL) async {
        BuiltInEngine.rememberChosenFile(url)
        await refresh()
    }

    private func storeChanged() {
        objectWillChange.send()
        if store.state != lastState, store.state == .ready { Task { await refresh() } }
        lastState = store.state
    }
}

/// The section in the editor.
struct BuiltInEngineSection: View {
    @Binding var selectedModelID: String?
    @ObservedObject private var models: BuiltInModelsModel = .shared

    var body: some View {
        BuiltInEngineSectionContent(
            rows: models.rows,
            selection: $selectedModelID,
            isLoading: models.isLoading,
            download: models.download,
            onChooseFile: chooseFile,
            onDownload: { models.store.start() },
            onCancelDownload: { models.store.cancel() },
            onRemoveDownload: { models.store.delete() }
        )
        .task {
            await models.refresh()
            // A workflow with no model yet starts on the best installed one. A model that was chosen and is
            // gone (an unplugged drive) is left alone: the picker says "Model not found" and the user decides.
            selectedModelID = BuiltInModels.selection(stored: selectedModelID, installed: models.entries)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose a GGUF model file")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let gguf = UTType(filenameExtension: "gguf") { panel.allowedContentTypes = [gguf] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await models.addChosenFile(url)
            selectedModelID = "file:" + url.standardizedFileURL.path
        }
    }
}
