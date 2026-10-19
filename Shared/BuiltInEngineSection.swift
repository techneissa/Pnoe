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
        rows.filter { SearchWords.matches([$0.name, $0.quantization ?? "", $0.sourceLabel].joined(separator: " "), query: query) }
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
                if showsCheckmark {
                    Spacer(minLength: 4)
                    // A quiet circle that becomes a check mark on the chosen row.
                    Image(systemName: isSelected ? "checkmark" : "circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.35))
                        .motionSymbolReplace(value: isSelected)
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

/// The popover's content for the models: the generic searchable list with the two-line model rows.
struct BuiltInModelPopoverContent: View {
    let rows: [BuiltInModelRow]
    let selectedID: String?
    var initialQuery = ""
    var startsShown = false
    let onSelect: (BuiltInModelRow) -> Void
    let onClose: () -> Void

    var body: some View {
        SearchablePopoverContent(
            items: rows,
            selectedID: selectedID,
            initialQuery: initialQuery,
            searchText: { [$0.name, $0.quantization ?? "", $0.sourceLabel].joined(separator: " ") },
            emptyText: rows.isEmpty ? "No models found" : nil,
            onSelect: onSelect,
            onClose: onClose,
            startsShown: startsShown
        ) { row, isSelected in
            BuiltInModelRowLabel(row: row, isSelected: isSelected, showsCheckmark: true)
        }
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
                    } else if isLoading {
                        // The folders are still being read: nothing to say about the stored model yet.
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                            Text("Looking for models…").foregroundStyle(.secondary)
                        }
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
        .motionHover(cornerRadius: 6, outset: 4)
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

/// When the download row is shown: nothing found on the Mac yet, or a download that is running, paused, failed
/// or finished (the row then says Downloaded and offers Remove, the only place that frees the 3 GB).
enum BuiltInDownloadVisibility {
    static func isVisible(installedCount: Int, state: FormatterModelDownloadState) -> Bool {
        switch state {
        case .notInstalled: installedCount == 0
        case .downloading, .paused, .verifying, .failed, .ready: true
        }
    }
}

extension FormatterModelDownloadState {
    /// Where the download is, for the symbol effects: running while it downloads, waits or checks.
    var motionPhase: MotionPhase {
        switch self {
        case .notInstalled: .idle
        case .downloading, .paused, .verifying: .running
        case .ready: .finished
        case .failed: .failed
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
    @State private var justFinished = false

    private var phase: MotionPhase { download.state.motionPhase }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(download.name)
                    if phase == .finished {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .motionBounce(when: justFinished)
                            .motionFade()
                    }
                }
                HStack(spacing: 4) {
                    if isFailure {
                        Image(systemName: Motion.symbol(for: .failed, idle: ""))
                            .motionJobSymbol(.failed)
                    }
                    Text(statusText)
                        .lineLimit(2)
                }
                .font(.callout)
                .foregroundStyle(isFailure ? Color.red : Color.secondary)
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
        .motion(.reveal, value: phase)
        .onChange(of: download.state) { old, new in
            // The finish bounce plays when a download ends, not each time the editor opens on a finished one.
            if old.motionPhase == .running, new == .ready { justFinished = true }
            if new != .ready { justFinished = false }
        }
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
            jobButton("Download", action: onDownload)
        case .downloading, .paused:
            jobButton("Cancel", action: onCancel)
        case .verifying:
            ProgressView().controlSize(.small)
        case .ready:
            Button("Remove", role: .destructive, action: onRemove)
                .motionHover(cornerRadius: 6)
        case .failed:
            jobButton("Retry", action: onDownload)
        }
    }

    /// The download button: its symbol is the job's (download, cancel while it runs, the error symbol after a
    /// failure), pulsing while it runs and wiggling once when it fails.
    private func jobButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: Motion.symbol(for: phase, idle: "arrow.down.circle", running: "xmark.circle"))
                    .motionJobSymbol(phase)
            }
        }
        .motionHover(cornerRadius: 6)
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
