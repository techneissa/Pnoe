import Foundation
import Testing
@testable import FormatterModels

@Suite("OllamaModelDiscovery")
struct OllamaModelDiscoveryTests {
    private func discovery(host: String, timeout: TimeInterval = 2) -> OllamaModelDiscovery {
        OllamaModelDiscovery(
            endpoint: URL(string: "http://\(host):11434")!,
            timeout: timeout,
            configuration: StubURLProtocol.configuration()
        )
    }

    private static let tags = """
    {"models":[
      {"name":"gemma4:e2b","model":"gemma4:e2b","size":7162394016,"details":{"family":"gemma4","families":["gemma4"],"quantization_level":"Q4_K_M"}},
      {"name":"qwen3.5:4b","model":"qwen3.5:4b","size":3400000000,"details":{"family":"qwen35","quantization_level":"Q4_K_M"}},
      {"name":"nomic-embed-text:latest","model":"nomic-embed-text:latest","size":274302450,"details":{"family":"nomic-bert","families":["nomic-bert"],"quantization_level":"F16"}},
      {"name":"bge-m3:latest","model":"bge-m3:latest","size":1200000000,"details":{"family":"bert"}},
      {"name":"custom-encoder:1","size":5,"details":{"family":"xlm-roberta-bert"}},
      {"name":"mxbai-embed-large","size":670000000,"details":{"family":"bert"}}
    ]}
    """

    @Test("lists chat models and filters embedding models by name and family")
    func filtersEmbeddings() async {
        let host = "ollama-list.test"
        StubURLProtocol.register(host: host) { request in
            #expect(request.url?.path == "/api/tags")
            #expect(request.httpMethod == "GET")
            return (200, [:], Data(Self.tags.utf8))
        }
        let entries = await discovery(host: host).fetch()
        #expect(entries.map(\.displayName) == ["gemma4:e2b", "qwen3.5:4b"])
        let gemma = entries[0]
        #expect(gemma.id == "ollama:gemma4:e2b")
        #expect(gemma.kind == .ollama)
        #expect(gemma.source == .ollama)
        #expect(gemma.sizeBytes == 7_162_394_016)
        #expect(gemma.quantization == "Q4_K_M")
        #expect(gemma.spec.identifier == "gemma4:e2b")
        #expect(gemma.spec.endpoint?.host == host)
        #expect(gemma.spec.modelURL == nil)
    }

    @Test("a daemon that is not running gives an empty list")
    func notRunning() async {
        // No handler registered for this host: the stub fails the connection like a closed port.
        let entries = await discovery(host: "ollama-down.test").fetch()
        #expect(entries.isEmpty)
    }

    @Test("a non-200 answer or a body that is not the tag list gives an empty list")
    func badAnswers() async {
        StubURLProtocol.register(host: "ollama-500.test") { _ in (500, [:], Data()) }
        StubURLProtocol.register(host: "ollama-garbage.test") { _ in (200, [:], Data("<html>not ollama</html>".utf8)) }
        #expect(await discovery(host: "ollama-500.test").fetch().isEmpty)
        #expect(await discovery(host: "ollama-garbage.test").fetch().isEmpty)
    }

    @Test("an empty model list is fine")
    func noModels() async {
        StubURLProtocol.register(host: "ollama-empty.test") { _ in (200, [:], Data(#"{"models":[]}"#.utf8)) }
        #expect(await discovery(host: "ollama-empty.test").fetch().isEmpty)
    }

    @Test("embedding rules")
    func embeddingRules() {
        #expect(ModelNameRules.isEmbeddingModel(name: "nomic-embed-text"))
        #expect(ModelNameRules.isEmbeddingModel(name: "BGE-large"))
        #expect(ModelNameRules.isEmbeddingModel(name: "x", families: ["nomic-bert"]))
        #expect(!ModelNameRules.isEmbeddingModel(name: "gemma4:e2b", families: ["gemma4"]))
        #expect(!ModelNameRules.isEmbeddingModel(name: "llama3.2:3b"))
    }
}
