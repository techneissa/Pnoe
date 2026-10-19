import FormatterCore
import FormatterModels
import Foundation

/// The models the Built-in engine can run: GGUF files already on the Mac (the Hugging Face cache, LM Studio's
/// folder, Ollama's model store with Ollama not running, files the user chose) and the optional Gemma 4 E2B
/// that Pnoe downloads. Listing reads folders and never copies, moves or loads anything.
enum BuiltInModels {
    /// The name the Workflow editor shows for this provider, and the raw value of the app's provider.
    static let providerName = "Built-in"

    static let chosenFilesKey = "builtInChosenModelFiles"

    /// The id of the downloaded model's entry. Other ids come from `FormatterModels`.
    static func downloadedID(for artifact: FormatterModelArtifact) -> String { "pnoe:\(artifact.modelName)" }

    /// Installed models, the downloaded one first. `chosenFiles` are the files picked with "Choose file…".
    static func installed(
        chosenFiles: [URL],
        artifact: FormatterModelArtifact = .gemma4E2B(),
        catalog: FormatterModelCatalog.Configuration = .init()
    ) async -> [FormatterModelEntry] {
        var configuration = catalog
        configuration.userChosenPaths = chosenFiles
        var entries = await FormatterModelCatalog(configuration: configuration).installedGGUFModels()
        if let url = artifact.installedModelFileURL {
            let downloaded = FormatterModelEntry(
                id: downloadedID(for: artifact),
                displayName: artifact.displayName,
                kind: .gguf,
                sizeBytes: artifact.expectedFileSize,
                source: .downloaded,
                quantization: "Q4_K_M",
                spec: RuntimeModelSpec(identifier: artifact.modelName, modelURL: url)
            )
            entries.removeAll { $0.id == downloaded.id }
            entries.insert(downloaded, at: 0)
        }
        return entries
    }

    /// The runtime spec for a stored model id, or nil when that model is gone (a file deleted, a drive unplugged).
    static func spec(
        forID id: String,
        chosenFiles: [URL],
        artifact: FormatterModelArtifact = .gemma4E2B(),
        catalog: FormatterModelCatalog.Configuration = .init()
    ) async -> RuntimeModelSpec? {
        var spec = await installed(chosenFiles: chosenFiles, artifact: artifact, catalog: catalog)
            .first { $0.id == id }?.spec
        spec?.contextLength = contextLength
        return spec
    }

    /// One context size for every workflow, so changing workflows never reloads the model.
    static let contextLength = 4096

    // MARK: Text for the picker

    static func sourceLabel(_ source: FormatterModelSource) -> String {
        switch source {
        case .ollama, .ollamaStore: "Ollama"
        case .huggingFaceCache: "Hugging Face"
        case .lmStudio: "LM Studio"
        case .userChosen: String(localized: "Chosen file")
        case .downloaded: String(localized: "Downloaded by Pnoe")
        }
    }

    /// "3.1 GB · Q4_K_M · Hugging Face"
    static func detail(of entry: FormatterModelEntry) -> String {
        var parts: [String] = []
        if let size = entry.sizeBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let quantization = entry.quantization { parts.append(quantization) }
        parts.append(sourceLabel(entry.source))
        return parts.joined(separator: " · ")
    }

    // MARK: Which model a workflow starts on

    /// A workflow set to Built-in with no model yet starts on the downloaded Gemma 4, else the smallest
    /// installed Gemma or Qwen instruct model, else nothing (the user picks). Base, code, vision and math
    /// variants and very small files are skipped, as for Ollama.
    static func suggested(from entries: [FormatterModelEntry]) -> FormatterModelEntry? {
        if let downloaded = entries.first(where: { $0.source == .downloaded }) { return downloaded }
        return entries
            .filter(isSuitable)
            .min { lhs, rhs in
                let left = lhs.sizeBytes ?? .max
                let right = rhs.sizeBytes ?? .max
                if left != right { return left < right }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }

    /// The stored id if that model is still installed, otherwise the suggestion. Nil when nothing fits.
    static func selection(stored: String?, installed entries: [FormatterModelEntry]) -> String? {
        if let stored, entries.contains(where: { $0.id == stored }) { return stored }
        return suggested(from: entries)?.id
    }

    private static let families = ["gemma", "qwen"]
    private static let excludedWords: Set<String> = ["base", "text", "pt", "coder", "code", "vl", "vision", "math", "guard"]
    private static let minimumSizeBytes: Int64 = 900_000_000

    private static func isSuitable(_ entry: FormatterModelEntry) -> Bool {
        guard entry.kind == .gguf else { return false }
        let name = entry.displayName.lowercased()
        guard families.contains(where: name.contains) else { return false }
        let words = Set(
            name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map { String($0.drop(while: \.isNumber)) })
        guard words.isDisjoint(with: excludedWords) else { return false }
        if let size = entry.sizeBytes, size < minimumSizeBytes { return false }
        return true
    }
}

/// Which providers the Workflow editor offers. The connected ones (an API key, a running Ollama, a CLI) are
/// listed in the app's provider order, and Built-in is always among them, in its place right after Ollama,
/// because it needs nothing connected.
enum WorkflowProviderList {
    /// `order` is every provider name in the order the editor shows them; `connected` the ones that are set up.
    static func names(order: [String], connected: Set<String>, builtIn: String) -> [String] {
        order.filter { $0 == builtIn || connected.contains($0) }
    }
}
