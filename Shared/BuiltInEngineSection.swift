import AppKit
import Combine
import FormatterModels
import SwiftUI
import UniformTypeIdentifiers

/// One installed model in the picker.
struct BuiltInModelRow: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String

    init(entry: FormatterModelEntry) {
        id = entry.id
        title = entry.displayName
        detail = BuiltInModels.detail(of: entry)
    }

    init(id: String, title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
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
        Picker("AI Model", selection: $selection) {
            if rows.isEmpty {
                Text(isLoading ? "Looking for models…" : "No models found").tag(String?.none)
            } else if selection == nil {
                Text("Choose a model").tag(String?.none)
            }
            if selection != nil, !rows.contains(where: { $0.id == selection }) {
                Text("Model not found").tag(selection)
            }
            ForEach(rows) { row in
                Text("\(row.title) · \(row.detail)").tag(Optional(row.id))
            }
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
        switch download.state {
        case .downloading(let fraction): fraction
        case .paused, .verifying: nil
        default: nil
        }
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

    init(store: FormatterModelStore = FormatterModelStore()) {
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
            // A workflow with no model yet starts on the best installed one; the user can change it.
            selectedModelID = BuiltInModels.selection(stored: selectedModelID, installed: models.entries) ?? selectedModelID
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
