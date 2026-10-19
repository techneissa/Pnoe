import Foundation

/// A runtime for tests and the eval harness: no model, scripted output.
public actor FakeRuntime: FormatterRuntime {
    public typealias Handler = @Sendable (GenerationRequest) async throws -> GenerationResult

    public nonisolated let id: FormatterRuntimeID
    private let handler: Handler
    private let delay: Duration?
    public private(set) var requests: [GenerationRequest] = []
    public private(set) var prepareCalls: [(RuntimeModelSpec, PromptPrefix)] = []
    public private(set) var cancelled: [UUID] = []
    public private(set) var unloadCount = 0
    private let prepareError: FormatterRuntimeError?

    public init(
        id: FormatterRuntimeID = .llama,
        delay: Duration? = nil,
        prepareError: FormatterRuntimeError? = nil,
        handler: @escaping Handler
    ) {
        self.id = id
        self.delay = delay
        self.prepareError = prepareError
        self.handler = handler
    }

    /// Always answers with `text`.
    public init(returning text: String, stopReason: StopReason = .eos, delay: Duration? = nil) {
        self.init(delay: delay) { _ in GenerationResult(text: text, stopReason: stopReason) }
    }

    /// Always throws `error` from `generate`.
    public init(throwing error: FormatterRuntimeError) {
        self.init { _ in throw error }
    }

    public func prepare(_ spec: RuntimeModelSpec, prefix: PromptPrefix) async throws {
        prepareCalls.append((spec, prefix))
        if let prepareError { throw prepareError }
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        requests.append(request)
        if let delay { try await Task.sleep(for: delay) }
        return try await handler(request)
    }

    public func cancel(_ requestID: UUID) async {
        cancelled.append(requestID)
    }

    public func unload() async {
        unloadCount += 1
    }
}
