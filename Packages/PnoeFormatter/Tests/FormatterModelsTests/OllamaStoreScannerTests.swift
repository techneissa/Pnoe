import Foundation
import Testing
@testable import FormatterModels

@Suite("Ollama model store on disk")
struct OllamaStoreScannerTests {
    /// A store in the shape Ollama writes: a manifest per tag and the model layer as a content-addressed blob.
    private func addModel(
        to store: TemporaryDirectory, host: String = "registry.ollama.ai", namespace: String = "library",
        model: String, tag: String, digest: String, blob: String = "GGUF" + String(repeating: "x", count: 96),
        mediaType: String = "application/vnd.ollama.image.model"
    ) throws {
        try store.file("blobs/sha256-\(digest)", contents: blob)
        let manifest = """
            {"schemaVersion":2,"layers":[
              {"mediaType":"\(mediaType)","digest":"sha256:\(digest)","size":\(blob.utf8.count)},
              {"mediaType":"application/vnd.ollama.image.template","digest":"sha256:ffff","size":10}]}
            """
        try store.file("manifests/\(host)/\(namespace)/\(model)/\(tag)", contents: manifest)
    }

    @Test("a pulled model becomes a GGUF entry pointing at its blob, named the way `ollama list` names it")
    func library() throws {
        let store = try TemporaryDirectory()
        try addModel(to: store, model: "gemma3", tag: "4b-it-q4_K_M", digest: "aaa111")
        let entries = OllamaStoreScanner(storeDirectory: store.url).scan()
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.displayName == "gemma3:4b-it-q4_K_M")
        #expect(entry.id == "ollama-store:gemma3:4b-it-q4_K_M")
        #expect(entry.kind == .gguf)
        #expect(entry.source == .ollamaStore)
        #expect(entry.sizeBytes == 100)
        #expect(entry.quantization == "Q4_K_M")
        #expect(entry.spec.modelURL?.lastPathComponent == "sha256-aaa111")
        #expect(entry.spec.identifier == "gemma3:4b-it-q4_K_M")
    }

    @Test("a user namespace or another registry stays in the name")
    func namespaces() throws {
        let store = try TemporaryDirectory()
        try addModel(to: store, namespace: "someone", model: "tiny", tag: "latest", digest: "bbb")
        try addModel(to: store, host: "models.example.test", namespace: "team", model: "chat", tag: "7b", digest: "ccc")
        let names = OllamaStoreScanner(storeDirectory: store.url).scan().map(\.displayName)
        #expect(names.contains("someone/tiny:latest"))
        #expect(names.contains("models.example.test/team/chat:7b"))
    }

    @Test("a blob that is not GGUF, a missing blob, an embedding model and a manifest without a model layer are left out")
    func skipped() throws {
        let store = try TemporaryDirectory()
        try addModel(to: store, model: "ok", tag: "1b", digest: "d1")
        try addModel(to: store, model: "safetensors-only", tag: "1b", digest: "d2", blob: "{\"not\":\"gguf\"}")
        try addModel(to: store, model: "nomic-embed-text", tag: "latest", digest: "d3")
        try addModel(to: store, model: "adapter", tag: "1b", digest: "d4", mediaType: "application/vnd.ollama.image.adapter")
        try store.file("manifests/registry.ollama.ai/library/dangling/1b", contents:
            #"{"layers":[{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:nothere","size":5}]}"#)
        try store.file("manifests/registry.ollama.ai/library/escape/1b", contents:
            #"{"layers":[{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:../../x","size":5}]}"#)
        #expect(OllamaStoreScanner(storeDirectory: store.url).scan().map(\.displayName) == ["ok:1b"])
    }

    @Test("a missing store is an empty list")
    func missing() throws {
        let store = try TemporaryDirectory()
        #expect(OllamaStoreScanner(storeDirectory: store.url.appendingPathComponent("nope")).scan().isEmpty)
    }

    @Test("OLLAMA_MODELS moves the store, otherwise it is under the home folder")
    func location() {
        let home = URL(fileURLWithPath: "/home-x", isDirectory: true)
        #expect(OllamaStoreScanner.storeDirectory(environment: [:], homeDirectory: home).path == "/home-x/.ollama/models")
        #expect(OllamaStoreScanner.storeDirectory(environment: ["OLLAMA_MODELS": "/data/ollama"], homeDirectory: home).path == "/data/ollama")
        #expect(OllamaStoreScanner.storeDirectory(environment: ["OLLAMA_MODELS": "  "], homeDirectory: home).path == "/home-x/.ollama/models")
    }

    @Test("the catalog lists GGUF files from every file store without asking the Ollama daemon")
    func catalogGGUFOnly() async throws {
        let home = try TemporaryDirectory()
        let hubBlob = try home.file("hub/models--org--m-GGUF/blobs/b", bytes: 11)
        try home.symlink("hub/models--org--m-GGUF/snapshots/r1/m-Q4_K_M.gguf", to: hubBlob)
        try home.file("hub/models--org--m-GGUF/refs/main", contents: "r1")
        try home.file("lm/pub/repo-GGUF/repo-Q8_0.gguf", bytes: 22)
        try home.file("lm/pub/mlx-4bit/config.json", contents: #"{"quantization":{"bits":4}}"#)
        try home.file("lm/pub/mlx-4bit/model.safetensors", bytes: 5)
        let chosen = try home.file("mine/x-Q5_K_M.gguf", bytes: 33)
        let ollama = try TemporaryDirectory()
        try addModel(to: ollama, model: "gemma3", tag: "1b", digest: "e1")

        // No stub is registered for this host: a request to it would fail the test by erroring, and the list
        // below must not depend on it.
        let catalog = FormatterModelCatalog(configuration: .init(
            ollamaEndpoint: URL(string: "http://never-asked.test:11434")!,
            environment: [:],
            homeDirectory: home.url,
            huggingFaceHubDirectory: home.url.appendingPathComponent("hub"),
            lmStudioModelsDirectory: home.url.appendingPathComponent("lm"),
            ollamaStoreDirectory: ollama.url,
            userChosenPaths: [chosen, chosen],
            urlSessionConfiguration: StubURLProtocol.configuration()
        ))
        let entries = await catalog.installedGGUFModels()
        #expect(entries.map(\.source) == [.huggingFaceCache, .lmStudio, .ollamaStore, .userChosen])
        #expect(entries.allSatisfy { $0.kind == .gguf })
        #expect(Set(entries.map(\.id)).count == 4)
    }
}
