import Foundation

/// An installed Ollama model with the `speech` capability and the voices `/api/show` lists for it.
struct OllamaSpeechModel: Equatable, Sendable {
    let name: String
    let voices: [String]
}

enum OllamaSpeechError: Error, Equatable {
    /// The server answered with a status other than 200. `message` is its error text, for example the voice list of a 400.
    case http(status: Int, message: String)
    case notHTTP
}

/// What the speaker needs from Ollama. Tests pass a fake.
protocol OllamaSpeechProviding: Sendable {
    /// The installed models that can speak. An unreachable daemon is an empty list, not an error.
    func speechModels() async -> [OllamaSpeechModel]
    /// The audio for `input` as raw PCM, in chunks as the server sends them. The stream fails if the request does.
    func audio(model: String, input: String, voice: String) -> AsyncThrowingStream<Data, Error>
}

/// The speech request: `POST {base}/v1/audio/speech` with `pcm`, the one format that streams without a header.
enum OllamaSpeechRequest {
    static func body(model: String, input: String, voice: String) -> Data {
        let object: [String: String] = [
            "model": model,
            "input": input,
            "voice": voice,
            "response_format": "pcm",
        ]
        // Sorted keys keep the body the same on every run, which makes it comparable in tests.
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    static func urlRequest(baseURL: URL, model: String, input: String, voice: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/audio/speech"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body(model: model, input: input, voice: voice)
        return request
    }
}

/// Finds speech models and streams audio from an Ollama daemon.
struct OllamaSpeechService: OllamaSpeechProviding {
    static let discoveryTimeout: TimeInterval = 2
    /// How much audio is gathered before it is handed on: 100 ms at 24 kHz, 16-bit mono.
    static let blockSize = 4_800

    var baseURL: URL
    /// Tests pass a configuration whose `protocolClasses` holds a stub.
    private let configuration: URLSessionConfiguration

    init(baseURL: URL, configuration: URLSessionConfiguration = .ephemeral) {
        self.baseURL = baseURL
        self.configuration = configuration
    }

    // MARK: Discovery

    private struct TagsResponse: Decodable {
        struct Model: Decodable {
            var name: String?
            var model: String?
        }
        var models: [Model]?
    }

    private struct ShowResponse: Decodable {
        var capabilities: [String]?
        var voices: [String]?

        private enum CodingKeys: String, CodingKey { case capabilities, voices }
        private struct Named: Decodable { var name: String? }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            capabilities = try? container.decode([String].self, forKey: .capabilities)
            // `voices` is a list of names; a list of objects with a `name` is read the same way.
            if let names = try? container.decode([String].self, forKey: .voices) {
                voices = names
            } else if let named = try? container.decode([Named].self, forKey: .voices) {
                voices = named.compactMap(\.name)
            }
        }
    }

    func speechModels() async -> [OllamaSpeechModel] {
        let session = makeSession(timeout: Self.discoveryTimeout)
        defer { session.finishTasksAndInvalidate() }

        var tagsRequest = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        tagsRequest.timeoutInterval = Self.discoveryTimeout
        guard let (data, response) = try? await session.data(for: tagsRequest),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let tags = try? JSONDecoder().decode(TagsResponse.self, from: data)
        else { return [] }

        let names = Array(Set((tags.models ?? []).compactMap { $0.name ?? $0.model }.filter { !$0.isEmpty }))
        let models = await withTaskGroup(of: OllamaSpeechModel?.self) { group in
            for name in names {
                group.addTask { await show(name, session: session) }
            }
            var found: [OllamaSpeechModel] = []
            for await model in group {
                if let model { found.append(model) }
            }
            return found
        }
        return Self.ordered(models)
    }

    private func show(_ name: String, session: URLSession) async -> OllamaSpeechModel? {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/show"))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.discoveryTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": name])
        guard let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let show = try? JSONDecoder().decode(ShowResponse.self, from: data),
            show.capabilities?.contains("speech") == true
        else { return nil }
        let voices = show.voices ?? []
        return OllamaSpeechModel(name: name, voices: voices.isEmpty ? [ReplySpeechSettings.defaultOllamaVoice] : voices)
    }

    /// `phonon` first (the Apache-licensed default), then the others by name.
    static func ordered(_ models: [OllamaSpeechModel]) -> [OllamaSpeechModel] {
        models.sorted { lhs, rhs in
            let lhsIsDefault = lhs.name == "phonon" || lhs.name == "phonon:latest"
            let rhsIsDefault = rhs.name == "phonon" || rhs.name == "phonon:latest"
            if lhsIsDefault != rhsIsDefault { return lhsIsDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: Audio

    func audio(model: String, input: String, voice: String) -> AsyncThrowingStream<Data, Error> {
        let request = OllamaSpeechRequest.urlRequest(baseURL: baseURL, model: model, input: input, voice: voice)
        let session = makeSession(timeout: 120)
        return AsyncThrowingStream { continuation in
            let task = Task {
                defer { session.finishTasksAndInvalidate() }
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw OllamaSpeechError.notHTTP }
                    guard http.statusCode == 200 else {
                        var body = Data()
                        for try await byte in bytes where body.count < 2_000 { body.append(byte) }
                        throw OllamaSpeechError.http(status: http.statusCode, message: Self.errorMessage(in: body))
                    }
                    var block = Data()
                    block.reserveCapacity(Self.blockSize)
                    for try await byte in bytes {
                        block.append(byte)
                        if block.count >= Self.blockSize {
                            continuation.yield(block)
                            block = Data()
                            block.reserveCapacity(Self.blockSize)
                        }
                    }
                    if !block.isEmpty { continuation.yield(block) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeSession(timeout: TimeInterval) -> URLSession {
        let configuration = (self.configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.timeoutIntervalForRequest = timeout
        return URLSession(configuration: configuration)
    }

    /// The `error` text of an Ollama error body, or the body itself.
    static func errorMessage(in body: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let text = object["error"] as? String { return text }
            if let error = object["error"] as? [String: Any], let text = error["message"] as? String { return text }
        }
        return String(data: body, encoding: .utf8) ?? ""
    }
}
