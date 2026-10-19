import FormatterCore
import Foundation

/// `FormatterRuntime` over a local Ollama server (`POST /api/chat`, not streamed). Foundation only, so the
/// app and the eval CLI share it.
///
/// Ollama owns the model process and its prompt cache: the runtime keeps the prefix and sends it with every
/// request, and Ollama reuses the cached prefix while the model stays loaded (`keepAlive`). Temperature is
/// always 0. A cap hit (`done_reason: "length"`) is `.cap`, a timeout or a cancel is `.interrupted` with the
/// text empty, and a normal end is `.eos`.
public actor OllamaRuntime: FormatterRuntime {
    public struct Configuration: Sendable, Equatable {
        /// Where the server listens when the model spec names no endpoint.
        public var defaultEndpoint: URL
        /// How long Ollama keeps the model loaded after a request: a duration such as `10m`, `-1` for ever,
        /// `0` to unload at once. Passed through as sent.
        public var keepAlive: String
        /// `think` for models that support it. `nil` leaves the field out. `false` turns thinking off on
        /// models that think by default; models without thinking support reject the field.
        public var think: Bool?
        /// Send one request with the prefix at `prepare` so Ollama loads the model and caches the prefix.
        public var warmUp: Bool
        /// Time allowed for the warm-up request (the model may load from disk).
        public var warmUpTimeout: TimeInterval

        public init(
            defaultEndpoint: URL = URL(string: "http://localhost:11434")!,
            keepAlive: String = "10m",
            think: Bool? = nil,
            warmUp: Bool = true,
            warmUpTimeout: TimeInterval = 60
        ) {
            self.defaultEndpoint = defaultEndpoint
            self.keepAlive = keepAlive
            self.think = think
            self.warmUp = warmUp
            self.warmUpTimeout = warmUpTimeout
        }
    }

    public nonisolated let id: FormatterRuntimeID = .ollama

    private let session: URLSession
    private let configuration: Configuration
    private var spec: RuntimeModelSpec?
    private var prefix = PromptPrefix(messages: [])
    private var inFlight: [UUID: Task<(Data, URLResponse), Error>] = [:]
    /// Ids cancelled before their request started, so `generate` returns at once.
    private var cancelledEarly: Set<UUID> = []

    public init(session: URLSession = .shared, configuration: Configuration = Configuration()) {
        self.session = session
        self.configuration = configuration
    }

    // MARK: FormatterRuntime

    public func prepare(_ spec: RuntimeModelSpec, prefix: PromptPrefix) async throws {
        self.spec = spec
        self.prefix = prefix
        guard configuration.warmUp else { return }
        // Prefix plus a throwaway user turn, one token out: loads the model and caches the prefix.
        let warm = [ChatMessage(role: .user, content: "warm-up")]
        let body = chatBody(spec: spec, messages: prefix.messages + warm, maxTokens: 1)
        let request = makeRequest(spec: spec, body: body, timeout: configuration.warmUpTimeout)
        do {
            let (data, response) = try await session.data(for: request)
            try Self.check(response: response, data: data)
        } catch let error as FormatterRuntimeError {
            throw error
        } catch {
            throw Self.map(transport: error)
        }
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        guard let spec else { throw FormatterRuntimeError.notReady }
        if cancelledEarly.remove(request.id) != nil { return Self.interrupted }
        let remaining = request.deadline - ContinuousClock.now
        let timeout = max(0.001, Self.seconds(remaining))
        let body = chatBody(spec: spec, messages: prefix.messages + request.suffix, maxTokens: request.maxTokens)
        let urlRequest = makeRequest(spec: spec, body: body, timeout: timeout)
        let session = self.session
        let task = Task { try await session.data(for: urlRequest) }
        inFlight[request.id] = task
        defer { inFlight[request.id] = nil }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            if let url = error as? URLError, url.code == .timedOut || url.code == .cancelled { return Self.interrupted }
            if error is CancellationError { return Self.interrupted }
            throw Self.map(transport: error)
        }
        try Self.check(response: response, data: data)
        return try Self.decode(data)
    }

    public func cancel(_ requestID: UUID) async {
        if let task = inFlight[requestID] {
            task.cancel()
        } else {
            if cancelledEarly.count > 64 { cancelledEarly.removeAll() }
            cancelledEarly.insert(requestID)
        }
    }

    /// Ollama has no unload call besides `keep_alive: 0` on a request; send one when the model is known.
    public func unload() async {
        guard let spec else { return }
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        let body: [String: Any] = ["model": spec.identifier, "messages": [], "keep_alive": 0, "stream": false]
        _ = try? await session.data(for: makeRequest(spec: spec, body: body, timeout: 5))
        self.spec = nil
    }

    // MARK: Requests

    private static let interrupted = GenerationResult(text: "", stopReason: .interrupted)

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    private func endpoint(for spec: RuntimeModelSpec) -> URL {
        (spec.endpoint ?? configuration.defaultEndpoint).appending(path: "api/chat")
    }

    func chatBody(spec: RuntimeModelSpec, messages: [ChatMessage], maxTokens: Int) -> [String: Any] {
        var options: [String: Any] = ["temperature": 0, "num_predict": maxTokens]
        if spec.contextLength > 0 { options["num_ctx"] = spec.contextLength }
        var body: [String: Any] = [
            "model": spec.identifier,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "stream": false,
            "keep_alive": Self.keepAliveValue(configuration.keepAlive),
            "options": options,
        ]
        if let think = configuration.think { body["think"] = think }
        return body
    }

    /// Ollama takes `keep_alive` as a number of seconds or a duration string; `-1` and `0` are numbers.
    private static func keepAliveValue(_ text: String) -> Any {
        if let number = Int(text) { return number }
        return text
    }

    private func makeRequest(spec: RuntimeModelSpec, body: [String: Any], timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: endpoint(for: spec), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    // MARK: Responses

    private struct ChatResponse: Decodable {
        struct Message: Decodable { var content: String? }
        var message: Message?
        var done: Bool?
        var doneReason: String?
        var promptEvalCount: Int?
        var evalCount: Int?
        var error: String?

        enum CodingKeys: String, CodingKey {
            case message, done, error
            case doneReason = "done_reason"
            case promptEvalCount = "prompt_eval_count"
            case evalCount = "eval_count"
        }
    }

    static func check(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw FormatterRuntimeError.failed("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(ChatResponse.self, from: data))?.error
                ?? String(decoding: data.prefix(200), as: UTF8.self)
            // A model that is not pulled is a setup problem, not a crash.
            if http.statusCode == 404 { throw FormatterRuntimeError.notReady }
            throw FormatterRuntimeError.failed("HTTP \(http.statusCode): \(detail)")
        }
    }

    static func decode(_ data: Data) throws -> GenerationResult {
        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
            throw FormatterRuntimeError.failed("unreadable response")
        }
        if let error = decoded.error { throw FormatterRuntimeError.failed(error) }
        guard let content = decoded.message?.content else { throw FormatterRuntimeError.failed("response has no message") }
        let stop: StopReason
        if decoded.done == false {
            stop = .interrupted
        } else if decoded.doneReason == "length" {
            stop = .cap
        } else {
            stop = .eos
        }
        return GenerationResult(
            text: content,
            stopReason: stop,
            promptTokens: decoded.promptEvalCount ?? 0,
            generatedTokens: decoded.evalCount ?? 0
        )
    }

    static func map(transport error: Error) -> FormatterRuntimeError {
        guard let url = error as? URLError else { return .failed(error.localizedDescription) }
        switch url.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
            // No server on the port: Ollama is not running.
            return .notReady
        case .timedOut: return .modelLoading
        case .cancelled: return .cancelled
        default: return .failed(url.localizedDescription)
        }
    }
}
