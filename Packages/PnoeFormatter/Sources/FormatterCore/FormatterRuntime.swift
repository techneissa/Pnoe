import Foundation

public enum FormatterRuntimeID: String, Sendable, Codable {
    case llama
    case mlx
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

/// Where a runtime finds the model. The download store (a later PR) produces these.
public struct RuntimeModelSpec: Sendable, Equatable {
    public var modelURL: URL
    public var contextLength: Int

    public init(modelURL: URL, contextLength: Int = 4096) {
        self.modelURL = modelURL
        self.contextLength = contextLength
    }
}

/// The fixed part of every request: system turn plus the shot turns. A runtime decodes it once at `prepare`
/// and reuses the KV cache, so the suffix is the only text evaluated per request.
public struct PromptPrefix: Sendable, Equatable {
    public var messages: [ChatMessage]

    public init(messages: [ChatMessage]) {
        self.messages = messages
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

    public init(
        id: UUID = UUID(),
        suffix: [ChatMessage],
        maxTokens: Int,
        deadline: ContinuousClock.Instant,
        temperature: Double = 0
    ) {
        self.id = id
        self.suffix = suffix
        self.maxTokens = maxTokens
        self.deadline = deadline
        self.temperature = temperature
    }
}

public enum StopReason: String, Sendable, Codable {
    /// The model emitted an end-of-generation token.
    case eos
    /// The output hit `maxTokens`.
    case cap
}

public struct GenerationResult: Sendable, Equatable {
    public var text: String
    public var stopReason: StopReason
    /// Prompt tokens evaluated for this request. After warm-up this equals the suffix length (prefix cache check).
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
    func generate(_ request: GenerationRequest) async throws -> GenerationResult
    /// Sets the flag the decode loop reads each token. Must make a running `generate` return soon.
    func cancel(_ requestID: UUID) async
    func unload() async
}
