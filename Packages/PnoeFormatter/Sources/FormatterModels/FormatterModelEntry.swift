import FormatterCore
import Foundation

/// How a runtime loads the model.
public enum FormatterModelKind: String, Sendable, Codable, CaseIterable {
    /// Served by an Ollama daemon over HTTP.
    case ollama
    /// A GGUF file for llama.cpp.
    case gguf
    /// A folder with `config.json` and safetensors for MLX.
    case mlx
}

/// Where discovery found the model.
public enum FormatterModelSource: String, Sendable, Codable, CaseIterable {
    case ollama
    case huggingFaceCache
    case lmStudio
    /// Ollama's model folder read from disk, with Ollama itself not running.
    case ollamaStore
    /// A model Pnoe downloaded itself.
    case downloaded
    case userChosen
}

/// One installed model the picker can offer. Discovery builds these; it never changes the files behind them.
public struct FormatterModelEntry: Sendable, Equatable, Identifiable {
    /// Stable across launches and across snapshot revisions, so a stored selection keeps matching.
    public var id: String
    public var displayName: String
    public var kind: FormatterModelKind
    /// Bytes on disk (Ollama: the size its tag list reports). Nil when unknown.
    public var sizeBytes: Int64?
    public var source: FormatterModelSource
    /// `Q4_K_M`, `4bit` and so on, when the name, tag list or config says.
    public var quantization: String?
    public var spec: RuntimeModelSpec

    public init(
        id: String,
        displayName: String,
        kind: FormatterModelKind,
        sizeBytes: Int64?,
        source: FormatterModelSource,
        quantization: String? = nil,
        spec: RuntimeModelSpec
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.source = source
        self.quantization = quantization
        self.spec = spec
    }
}
