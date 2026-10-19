import FormatterCore
import Foundation

/// Lists the models an Ollama daemon has pulled, with one `GET /api/tags`. It never asks Ollama to load or run
/// anything, and a daemon that is not running is an empty list, not an error.
public struct OllamaModelDiscovery: Sendable {
    public static let defaultEndpoint = URL(string: "http://localhost:11434")!
    public static let defaultTimeout: TimeInterval = 2

    public var endpoint: URL
    public var timeout: TimeInterval
    /// Tests pass a configuration whose `protocolClasses` holds a stub.
    private let configuration: URLSessionConfiguration

    public init(
        endpoint: URL = OllamaModelDiscovery.defaultEndpoint,
        timeout: TimeInterval = OllamaModelDiscovery.defaultTimeout,
        configuration: URLSessionConfiguration = .ephemeral
    ) {
        self.endpoint = endpoint
        self.timeout = timeout
        self.configuration = configuration
    }

    private struct TagsResponse: Decodable {
        struct Model: Decodable {
            struct Details: Decodable {
                var family: String?
                var families: [String]?
                var quantization_level: String?
            }
            var name: String?
            var model: String?
            var size: Int64?
            var details: Details?
        }
        var models: [Model]?
    }

    public func fetch() async -> [FormatterModelEntry] {
        var request = URLRequest(url: endpoint.appendingPathComponent("api/tags"))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout

        let configuration = (self.configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let tags = try? JSONDecoder().decode(TagsResponse.self, from: data)
        else { return [] }

        var seen = Set<String>()
        var result: [FormatterModelEntry] = []
        for model in tags.models ?? [] {
            guard let name = (model.name ?? model.model), !name.isEmpty, seen.insert(name).inserted else { continue }
            let families = (model.details?.families ?? []) + [model.details?.family].compactMap { $0 }
            if ModelNameRules.isEmbeddingModel(name: name, families: families) { continue }
            result.append(
                FormatterModelEntry(
                    id: "ollama:\(name)",
                    displayName: name,
                    kind: .ollama,
                    sizeBytes: model.size,
                    source: .ollama,
                    quantization: model.details?.quantization_level.flatMap { $0.isEmpty ? nil : $0 },
                    spec: RuntimeModelSpec(identifier: name, endpoint: endpoint)
                )
            )
        }
        return result.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}
