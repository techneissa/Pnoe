import FormatterCore
import FormatterModels
import Foundation

/// The models the Built-in engine can run: GGUF files (llama.cpp) and MLX folders (MLX) already on the Mac
/// (the Hugging Face cache, LM Studio's folder, Ollama's model store with Ollama not running, files and folders
/// the user chose) and the optional Gemma 4 E2B that Pnoe downloads. Listing reads folders and never copies,
/// moves or loads anything. A model's spec names its engine, which routes it to the llama.cpp or the MLX service.
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
        var entries = await FormatterModelCatalog(configuration: configuration).installedFileModels()
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

    /// Whether the model with this id is on the Mac now. Reads the model folders on the calling thread, for the
    /// moment a new workflow decides whether it can inherit Built-in.
    static func isInstalled(
        modelID: String?,
        chosenFiles: [URL],
        artifact: FormatterModelArtifact = .gemma4E2B(),
        catalog: FormatterModelCatalog.Configuration = .init()
    ) -> Bool {
        guard let modelID, !modelID.isEmpty else { return false }
        if modelID == downloadedID(for: artifact) { return artifact.installedModelFileURL != nil }
        var configuration = catalog
        configuration.userChosenPaths = chosenFiles
        return FormatterModelCatalog(configuration: configuration).installedFileModelsNow().contains { $0.id == modelID }
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

    /// The badge on an MLX model.
    static let mlxLabel = "MLX"

    static func sourceLabel(_ source: FormatterModelSource) -> String {
        switch source {
        case .ollama, .ollamaStore: "Ollama"
        case .huggingFaceCache: "Hugging Face"
        case .lmStudio: "LM Studio"
        case .userChosen: String(localized: "File")
        case .downloaded: String(localized: "Downloaded")
        }
    }

    /// The model's name without its quantization: `gemma-4-E2B-it-Q4_K_M` is `gemma-4-E2B-it`. The picker shows
    /// the quantization as a badge of its own. A name that does not end in its quantization is left as it is.
    static func title(of entry: FormatterModelEntry) -> String {
        guard let quantization = entry.quantization else { return entry.displayName }
        let name = entry.displayName
        guard let range = name.range(
            of: "[-_.:]?" + NSRegularExpression.escapedPattern(for: quantization) + "$", options: [.regularExpression, .caseInsensitive]),
            range.lowerBound > name.startIndex
        else { return name }
        return String(name[..<range.lowerBound])
    }

    /// "3.1 GB · Q4_K_M · Hugging Face" (an MLX model: "2.0 GB · 4bit · MLX · Hugging Face")
    static func detail(of entry: FormatterModelEntry) -> String {
        var parts: [String] = []
        if let size = entry.sizeBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let quantization = entry.quantization { parts.append(quantization) }
        if entry.kind == .mlx { parts.append(mlxLabel) }
        parts.append(sourceLabel(entry.source))
        return parts.joined(separator: " · ")
    }

    // MARK: Which model a workflow starts on

    /// A workflow set to Built-in with no model yet starts on Gemma 4 E2B (the one Pnoe downloads, else any
    /// installed copy of it, since the prompt and the guards are tuned on it), else the smallest installed
    /// Gemma or Qwen instruct model, else nothing (the user picks). Base, code, vision and math variants and
    /// very small files are skipped, as for Ollama. Only GGUF files are suggested: an MLX model is never
    /// preselected, the user picks it.
    static func suggested(from entries: [FormatterModelEntry]) -> FormatterModelEntry? {
        if let downloaded = entries.first(where: { $0.source == .downloaded }) { return downloaded }
        if let gemma = entries.filter(isGemma4E2B).min(by: { ($0.sizeBytes ?? .max) < ($1.sizeBytes ?? .max) }) { return gemma }
        return entries
            .filter(isSuitable)
            .min { lhs, rhs in
                let left = lhs.sizeBytes ?? .max
                let right = rhs.sizeBytes ?? .max
                if left != right { return left < right }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }

    /// A stored id stays, whether or not that model is installed now: a model that went missing (an unplugged
    /// drive) shows as "Model not found" and the user decides. Only a workflow with no model stored gets the
    /// suggestion, and nil when nothing fits.
    static func selection(stored: String?, installed entries: [FormatterModelEntry]) -> String? {
        if let stored, !stored.isEmpty { return stored }
        return suggested(from: entries)?.id
    }

    /// `gemma-4-E2B-it-Q4_K_M`, `gemma4:e2b`, `Gemma 4 E2B`.
    static func isGemma4E2B(_ entry: FormatterModelEntry) -> Bool {
        entry.kind == .gguf
            && entry.displayName.range(of: #"gemma[-_ ]?4.*e2b"#, options: [.regularExpression, .caseInsensitive]) != nil
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

/// Whether any workflow still uses Built-in, so the model can be freed when none does.
enum BuiltInUsage {
    struct Workflow: Equatable {
        let isAIEnabled: Bool
        let providerName: String?
    }

    static func isUsed(by workflows: [Workflow]) -> Bool {
        workflows.contains { $0.isAIEnabled && $0.providerName == BuiltInModels.providerName }
    }
}
