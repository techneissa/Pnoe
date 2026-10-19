import FormatterCore
import Foundation

/// `FormatterRuntime` over a local `llama-server` (llama.cpp's OpenAI-compatible `/v1/chat/completions`).
/// The user starts the server in a terminal; the harness only talks to it. The server keeps the prompt cache
/// (`cache_prompt`), so the prefix is sent with every request and reused.
public actor LlamaServerRuntime: FormatterRuntime {
    public struct Configuration: Sendable, Equatable {
        public var defaultEndpoint: URL
        /// `false` sends `chat_template_kwargs.enable_thinking = false` for models that think by default.
        public var enableThinking: Bool?
        public var warmUp: Bool

        public init(defaultEndpoint: URL = URL(string: "http://127.0.0.1:8080")!, enableThinking: Bool? = nil, warmUp: Bool = true) {
            self.defaultEndpoint = defaultEndpoint
            self.enableThinking = enableThinking
            self.warmUp = warmUp
        }
    }

    public nonisolated let id: FormatterRuntimeID = .llama

    private let session: URLSession
    private let configuration: Configuration
    private var spec: RuntimeModelSpec?
    private var prefix = PromptPrefix(messages: [])
    private var inFlight: [UUID: Task<(Data, URLResponse), Error>] = [:]

    public init(session: URLSession = .shared, configuration: Configuration = Configuration()) {
        self.session = session
        self.configuration = configuration
    }

    public func prepare(_ spec: RuntimeModelSpec, prefix: PromptPrefix) async throws {
        self.spec = spec
        self.prefix = prefix
        guard configuration.warmUp else { return }
        let body = chatBody(spec: spec, messages: prefix.messages + [ChatMessage(role: .user, content: "warm-up")], maxTokens: 1)
        do {
            let (data, response) = try await session.data(for: makeRequest(spec: spec, body: body, timeout: 60))
            try Self.check(response: response, data: data)
        } catch let error as FormatterRuntimeError {
            throw error
        } catch {
            throw Self.map(transport: error)
        }
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        guard let spec else { throw FormatterRuntimeError.notReady }
        let remaining = request.deadline - ContinuousClock.now
        let parts = remaining.components
        let timeout = max(0.001, TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18)
        let body = chatBody(spec: spec, messages: prefix.messages + request.suffix, maxTokens: request.maxTokens)
        let urlRequest = makeRequest(spec: spec, body: body, timeout: timeout)
        let session = self.session
        let task = Task { try await session.data(for: urlRequest) }
        inFlight[request.id] = task
        defer { inFlight[request.id] = nil }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            if let url = error as? URLError, url.code == .timedOut || url.code == .cancelled { return GenerationResult(text: "", stopReason: .interrupted) }
            if error is CancellationError { return GenerationResult(text: "", stopReason: .interrupted) }
            throw Self.map(transport: error)
        }
        try Self.check(response: response, data: data)
        return try Self.decode(data)
    }

    public func cancel(_ requestID: UUID) async { inFlight[requestID]?.cancel() }

    /// The server owns the model; there is nothing to unload from here.
    public func unload() async {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        spec = nil
    }

    // MARK: Wire

    func chatBody(spec: RuntimeModelSpec, messages: [ChatMessage], maxTokens: Int) -> [String: Any] {
        var body: [String: Any] = [
            "model": spec.identifier,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "temperature": 0,
            "max_tokens": maxTokens,
            "stream": false,
            "cache_prompt": true,
        ]
        if let thinking = configuration.enableThinking { body["chat_template_kwargs"] = ["enable_thinking": thinking] }
        return body
    }

    private func makeRequest(spec: RuntimeModelSpec, body: [String: Any], timeout: TimeInterval) -> URLRequest {
        let base = spec.endpoint ?? configuration.defaultEndpoint
        var request = URLRequest(url: base.appending(path: "v1/chat/completions"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    private struct Completion: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { var content: String? }
            var message: Message?
            var finishReason: String?
            enum CodingKeys: String, CodingKey { case message; case finishReason = "finish_reason" }
        }
        struct Usage: Decodable {
            var promptTokens: Int?
            var completionTokens: Int?
            enum CodingKeys: String, CodingKey { case promptTokens = "prompt_tokens"; case completionTokens = "completion_tokens" }
        }
        struct Timings: Decodable { var promptN: Int?; enum CodingKeys: String, CodingKey { case promptN = "prompt_n" } }
        var choices: [Choice]?
        var usage: Usage?
        var timings: Timings?
    }

    static func check(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw FormatterRuntimeError.failed("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            // 503 is llama-server saying "Loading model".
            if http.statusCode == 503 { throw FormatterRuntimeError.modelLoading }
            throw FormatterRuntimeError.failed("HTTP \(http.statusCode): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
    }

    static func decode(_ data: Data) throws -> GenerationResult {
        guard let completion = try? JSONDecoder().decode(Completion.self, from: data), let choice = completion.choices?.first,
              let content = choice.message?.content else {
            throw FormatterRuntimeError.failed("unreadable response")
        }
        let stop: StopReason
        switch choice.finishReason {
        case "length": stop = .cap
        case "stop", nil: stop = .eos
        default: stop = .eos
        }
        // `timings.prompt_n` counts tokens evaluated after the cache hit; `usage` counts the whole prompt.
        return GenerationResult(
            text: content,
            stopReason: stop,
            promptTokens: completion.timings?.promptN ?? completion.usage?.promptTokens ?? 0,
            generatedTokens: completion.usage?.completionTokens ?? 0
        )
    }

    static func map(transport error: Error) -> FormatterRuntimeError {
        guard let url = error as? URLError else { return .failed(error.localizedDescription) }
        switch url.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed: return .notReady
        case .timedOut: return .modelLoading
        case .cancelled: return .cancelled
        default: return .failed(url.localizedDescription)
        }
    }
}
