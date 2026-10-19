import Foundation
import Testing
@testable import FormatterModels

@Suite("FormatterModelCatalog")
struct FormatterModelCatalogTests {
    @Test("combines Ollama, the cache, LM Studio and chosen files, in that order, from temporary stores only")
    func combines() async throws {
        let home = try TemporaryDirectory()
        let hubBlob = try home.file("hub/models--org--m-GGUF/blobs/b", bytes: 11)
        try home.symlink("hub/models--org--m-GGUF/snapshots/r1/m-Q4_K_M.gguf", to: hubBlob)
        try home.file("hub/models--org--m-GGUF/refs/main", contents: "r1")
        try home.file("lm/pub/repo-GGUF/repo-Q8_0.gguf", bytes: 22)
        let chosen = try home.file("mine/x-Q5_K_M.gguf", bytes: 33)

        let host = "catalog.test"
        StubURLProtocol.register(host: host) { _ in
            (200, [:], Data(#"{"models":[{"name":"gemma4:e2b","size":5}]}"#.utf8))
        }
        let catalog = FormatterModelCatalog(configuration: .init(
            ollamaEndpoint: URL(string: "http://\(host):11434")!,
            environment: [:],
            homeDirectory: home.url,
            huggingFaceHubDirectory: home.url.appendingPathComponent("hub"),
            lmStudioModelsDirectory: home.url.appendingPathComponent("lm"),
            userChosenPaths: [chosen, chosen],
            urlSessionConfiguration: StubURLProtocol.configuration()
        ))
        let entries = await catalog.installedModels()
        #expect(entries.map(\.source) == [.ollama, .huggingFaceCache, .lmStudio, .userChosen])
        #expect(Set(entries.map(\.id)).count == 4)
    }

    @Test("with Ollama down and empty stores the list is empty")
    func empty() async throws {
        let home = try TemporaryDirectory()
        let catalog = FormatterModelCatalog(configuration: .init(
            ollamaEndpoint: URL(string: "http://catalog-down.test:11434")!,
            environment: [:],
            homeDirectory: home.url,
            urlSessionConfiguration: StubURLProtocol.configuration()
        ))
        #expect(await catalog.installedModels().isEmpty)
    }

    @Test("discovery leaves every file as it found it")
    func readOnly() async throws {
        let home = try TemporaryDirectory()
        try home.file("lm/pub/repo-GGUF/repo-Q8_0.gguf", bytes: 22)
        try home.file("lm/pub/repo-GGUF/notes.txt", bytes: 3)
        func snapshot() throws -> [String] {
            let enumerator = FileManager.default.enumerator(at: home.url, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])!
            return try enumerator.compactMap { item in
                let url = try #require(item as? URL)
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return "\(url.path) \(values.fileSize ?? -1) \(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            }.sorted()
        }
        let before = try snapshot()
        let catalog = FormatterModelCatalog(configuration: .init(
            ollamaEndpoint: URL(string: "http://catalog-ro.test:11434")!,
            environment: [:],
            homeDirectory: home.url,
            huggingFaceHubDirectory: home.url.appendingPathComponent("hub"),
            lmStudioModelsDirectory: home.url.appendingPathComponent("lm"),
            urlSessionConfiguration: StubURLProtocol.configuration()
        ))
        #expect(await catalog.installedModels().count == 1)
        #expect(try snapshot() == before)
    }
}
