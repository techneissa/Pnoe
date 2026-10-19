import CryptoKit
import Foundation

public enum FormatterRuntimeID: String, Sendable, Codable {
    case llama
    case mlx
    /// An Ollama server reached over HTTP.
    case ollama
    /// Any chat provider the host app already talks to (cloud API, custom endpoint, local CLI).
    case chatCompletion
}

public struct ChatMessage: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Codable {
        case system
        case user
        case assistant
    }

    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// Which model a runtime should use. Generic on purpose: a file-backed runtime (llama.cpp, MLX) reads
/// `modelURL`, an HTTP runtime (Ollama) reads `identifier` and `endpoint`.
public struct RuntimeModelSpec: Sendable, Equatable {
    /// A name the runtime understands: an Ollama tag such as `gemma4:e2b`, or a file or folder name.
    public var identifier: String
    /// The model file or folder, for runtimes that load from disk.
    public var modelURL: URL?
    /// The server, for runtimes that talk HTTP.
    public var endpoint: URL?
    public var contextLength: Int
    /// Which engine loads the model: `.mlx` for an MLX folder. Nil is the file-based default (llama.cpp), so every
    /// spec made before MLX existed keeps its meaning. A router in front of several runtimes reads this.
    public var backend: FormatterRuntimeID?

    public init(
        identifier: String, modelURL: URL? = nil, endpoint: URL? = nil, contextLength: Int = 4096,
        backend: FormatterRuntimeID? = nil
    ) {
        self.identifier = identifier
        self.modelURL = modelURL
        self.endpoint = endpoint
        self.contextLength = contextLength
        self.backend = backend
    }

    public init(modelURL: URL, contextLength: Int = 4096, backend: FormatterRuntimeID? = nil) {
        self.init(
            identifier: modelURL.lastPathComponent, modelURL: modelURL, contextLength: contextLength, backend: backend)
    }
}

/// The fixed part of every request: system turn plus the shot turns. A runtime that owns a KV cache decodes
/// it once at `prepare` and evaluates only the suffix per request. A runtime that cannot hold a cache (an
/// HTTP server may evict it) keeps the prefix and sends it with every request; the pipeline assumes nothing.
public struct PromptPrefix: Sendable, Equatable {
    public var messages: [ChatMessage]

    public init(messages: [ChatMessage]) {
        self.messages = messages
    }

    /// A short stable name for this prefix (a SHA-256 of its messages). A request carries it so a runtime that
    /// has been prepared with another prefix in the meantime can switch back before it generates.
    public var key: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(messages)) ?? Data()
        return SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

public struct GenerationRequest: Sendable, Equatable {
    public var id: UUID
    /// The turns after the prefix (one user turn).
    public var suffix: [ChatMessage]
    public var maxTokens: Int
    public var deadline: ContinuousClock.Instant
    /// Always 0. Carried so a backend can assert it.
    public var temperature: Double
    /// `PromptPrefix.key` of the prefix this request was built for. A runtime shared by several workflows
    /// switches to that prefix when another one was prepared in between; nil means "whatever is current".
    public var prefixKey: String?

    public init(
        id: UUID = UUID(),
        suffix: [ChatMessage],
        maxTokens: Int,
        deadline: ContinuousClock.Instant,
        temperature: Double = 0,
        prefixKey: String? = nil
    ) {
        self.id = id
        self.suffix = suffix
        self.maxTokens = maxTokens
        self.deadline = deadline
        self.temperature = temperature
        self.prefixKey = prefixKey
    }
}

public enum StopReason: String, Sendable, Codable {
    /// The model emitted an end-of-generation token. The only reason whose text may be used.
    case eos
    /// The output hit `maxTokens`.
    case cap
    /// The runtime stopped early (deadline or cancel) and the text is partial. HTTP servers report this as
    /// a dropped stream or a missing done flag.
    case interrupted
}

public struct GenerationResult: Sendable, Equatable {
    public var text: String
    public var stopReason: StopReason
    /// Prompt tokens evaluated for this request. With a prefix cache and after warm-up this equals the suffix
    /// length (the eval's cache check); 0 when the runtime does not report it.
    public var promptTokens: Int
    public var generatedTokens: Int

    public init(text: String, stopReason: StopReason = .eos, promptTokens: Int = 0, generatedTokens: Int = 0) {
        self.text = text
        self.stopReason = stopReason
        self.promptTokens = promptTokens
        self.generatedTokens = generatedTokens
    }
}

/// What a runtime throws. The pipeline maps each case to a `FallbackReason`.
public enum FormatterRuntimeError: Error, Sendable, Equatable {
    /// The model is still loading and the wait budget ran out.
    case modelLoading
    case notReady
    /// The runtime process died.
    case crashed
    case cancelled
    case failed(String)
}

public protocol FormatterRuntime: Sendable {
    var id: FormatterRuntimeID { get }
    func prepare(_ spec: RuntimeModelSpec, prefix: PromptPrefix) async throws
    /// `prepare` for a caller that has a deadline: a runtime that can load for a long time (a model of a few GB)
    /// waits no longer than the deadline, and a load that is still running goes on for the next caller. The
    /// default ignores the deadline.
    func prepare(_ spec: RuntimeModelSpec, prefix: PromptPrefix, deadline: ContinuousClock.Instant) async throws
    func generate(_ request: GenerationRequest) async throws -> GenerationResult
    /// Sets the flag the decode loop reads each token. Must make a running `generate` return soon.
    func cancel(_ requestID: UUID) async
    func unload() async
}

extension FormatterRuntime {
    public func prepare(_ spec: RuntimeModelSpec, prefix: PromptPrefix, deadline: ContinuousClock.Instant) async throws {
        try await prepare(spec, prefix: prefix)
    }
}
