import FormatterCore
import Foundation
import Testing
@testable import FormatterModels

@Suite("Hugging Face cache, LM Studio and chosen paths")
struct ModelFolderScannerTests {
    private let mlxConfig = #"{"model_type":"qwen3","quantization":{"group_size":64,"bits":4}}"#

    // MARK: Hugging Face cache

    /// Builds `models--org--name/snapshots/<rev>/` with real blobs behind symlinks, as the hub cache does.
    private func snapshot(
        in cache: TemporaryDirectory, repo: String, revision: String = "abc123", files: [String: Int], setMain: Bool = true
    ) throws {
        let folder = "models--" + repo.replacingOccurrences(of: "/", with: "--")
        for (name, size) in files {
            let blob = try cache.file("\(folder)/blobs/\(UUID().uuidString)", bytes: size)
            try cache.symlink("\(folder)/snapshots/\(revision)/\(name)", to: blob)
        }
        if setMain { try cache.file("\(folder)/refs/main", contents: revision) }
    }

    @Test("a GGUF in the cache becomes a gguf entry with its real size, and mmproj and draft files are skipped")
    func huggingFaceGGUF() throws {
        let cache = try TemporaryDirectory()
        try snapshot(in: cache, repo: "unsloth/gemma-4-E2B-it-GGUF", files: [
            "gemma-4-E2B-it-Q4_K_M.gguf": 1000,
            "mmproj-F16.gguf": 50,
            "gemma-4-E2B-it-draft-Q8_0.gguf": 60,
            "README.md": 5,
        ])
        let entries = HuggingFaceCacheScanner(hubDirectory: cache.url).scan()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.kind == .gguf)
        #expect(entry.source == .huggingFaceCache)
        #expect(entry.id == "hf:unsloth/gemma-4-E2B-it-GGUF/gemma-4-E2B-it-Q4_K_M.gguf")
        #expect(entry.displayName == "gemma-4-E2B-it-Q4_K_M")
        #expect(entry.quantization == "Q4_K_M")
        #expect(entry.sizeBytes == 1000)
        #expect(entry.spec.modelURL?.lastPathComponent == "gemma-4-E2B-it-Q4_K_M.gguf")
        #expect(entry.spec.modelURL?.path.contains("/snapshots/abc123/") == true)
    }

    @Test("several quantizations in one repo are separate entries; a split model is one entry with the shards added up")
    func quantizationsAndShards() throws {
        let cache = try TemporaryDirectory()
        try snapshot(in: cache, repo: "org/model-GGUF", files: [
            "model-Q4_K_M.gguf": 10,
            "model-Q8_0.gguf": 20,
            "BF16/model-BF16-00001-of-00002.gguf": 30,
            "BF16/model-BF16-00002-of-00002.gguf": 40,
        ])
        let entries = HuggingFaceCacheScanner(hubDirectory: cache.url).scan()
        #expect(entries.count == 3)
        let split = try #require(entries.first { $0.id.hasSuffix("model-BF16-00001-of-00002.gguf") })
        #expect(split.sizeBytes == 70)
        #expect(split.displayName == "model-BF16")
        #expect(split.quantization == "BF16")
        #expect(Set(entries.compactMap(\.quantization)) == ["Q4_K_M", "Q8_0", "BF16"])
    }

    @Test("an MLX build in the cache becomes an mlx entry")
    func huggingFaceMLX() throws {
        let cache = try TemporaryDirectory()
        try snapshot(in: cache, repo: "mlx-community/Qwen3-4B-4bit", files: [
            "model-00001-of-00002.safetensors": 100,
            "model-00002-of-00002.safetensors": 60,
            "tokenizer.json": 4,
        ])
        let config = try cache.file("cfg", contents: mlxConfig)
        try cache.symlink("models--mlx-community--Qwen3-4B-4bit/snapshots/abc123/config.json", to: config)

        let entries = HuggingFaceCacheScanner(hubDirectory: cache.url).scan()
        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.kind == .mlx)
        #expect(entry.id == "hf:mlx-community/Qwen3-4B-4bit")
        #expect(entry.sizeBytes == 160)
        #expect(entry.quantization == "4bit")
        #expect(entry.spec.modelURL?.lastPathComponent == "abc123")
        // The spec says which engine loads it, so the Built-in engine routes it to the MLX service.
        #expect(entry.spec.backend == .mlx)
    }

    @Test("a GGUF file's spec names no backend, so it stays on the default engine")
    func ggufHasNoBackend() throws {
        let cache = try TemporaryDirectory()
        try snapshot(in: cache, repo: "unsloth/gemma-4-E2B-it-GGUF", files: ["gemma-4-E2B-it-Q4_K_M.gguf": 100])
        let entry = try #require(HuggingFaceCacheScanner(hubDirectory: cache.url).scan().first)
        #expect(entry.kind == .gguf)
        #expect(entry.spec.backend == nil)
    }

    @Test("MLX rule: another org needs an MLX or bit-width name and a quantization entry in config.json")
    func mlxNameRule() throws {
        let cache = try TemporaryDirectory()
        // Quantized, named for it: yes.
        try snapshot(in: cache, repo: "someone/Phi-4-mlx", files: ["model.safetensors": 10, "config.json": 10])
        // Same name but config has no quantization: no.
        try snapshot(in: cache, repo: "someone/Other-mlx", files: ["model.safetensors": 10])
        // A plain transformers repo: no.
        try snapshot(in: cache, repo: "meta/Llama-plain", files: ["model.safetensors": 10, "config.json": 10])

        func writeConfig(repo: String, contents: String) throws {
            let folder = "models--" + repo.replacingOccurrences(of: "/", with: "--") + "/snapshots/abc123/config.json"
            let target = cache.url.appendingPathComponent(folder)
            try? FileManager.default.removeItem(at: target)
            try contents.write(to: target, atomically: true, encoding: .utf8)
        }
        try writeConfig(repo: "someone/Phi-4-mlx", contents: mlxConfig)
        try writeConfig(repo: "someone/Other-mlx", contents: #"{"model_type":"x"}"#)
        try writeConfig(repo: "meta/Llama-plain", contents: #"{"model_type":"llama"}"#)

        let ids = HuggingFaceCacheScanner(hubDirectory: cache.url).scan().map(\.id)
        #expect(ids == ["hf:someone/Phi-4-mlx"])
    }

    @Test("embedding repos, datasets, dangling links and empty snapshots are skipped")
    func skipped() throws {
        let cache = try TemporaryDirectory()
        try snapshot(in: cache, repo: "nomic-ai/nomic-embed-text-v1.5-GGUF", files: ["nomic-embed-text-v1.5.Q4_K_M.gguf": 10])
        try cache.file("datasets--org--data/snapshots/abc/model.gguf")
        try cache.symlink("models--org--broken/snapshots/abc/model-Q4_K_M.gguf", to: cache.url.appendingPathComponent("missing-blob"))
        _ = try cache.directory("models--org--empty/snapshots/abc")
        try cache.file("stray.gguf")
        #expect(HuggingFaceCacheScanner(hubDirectory: cache.url).scan().isEmpty)
    }

    @Test("without refs/main the newest snapshot is used")
    func newestSnapshot() throws {
        let cache = try TemporaryDirectory()
        try snapshot(in: cache, repo: "org/m-GGUF", revision: "old", files: ["m-Q4_K_M.gguf": 10], setMain: false)
        try snapshot(in: cache, repo: "org/m-GGUF", revision: "new", files: ["m-Q4_K_M.gguf": 99], setMain: false)
        let old = cache.url.appendingPathComponent("models--org--m-GGUF/snapshots/old")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: old.path)
        let entries = HuggingFaceCacheScanner(hubDirectory: cache.url).scan()
        #expect(entries.count == 1)
        #expect(entries.first?.sizeBytes == 99)
    }

    @Test("the cache folder follows HF_HUB_CACHE, then HF_HOME, then XDG_CACHE_HOME, then the home default")
    func cacheLocation() {
        let home = URL(fileURLWithPath: "/home/someone")
        func hub(_ environment: [String: String]) -> String {
            HuggingFaceCacheScanner.hubDirectory(environment: environment, homeDirectory: home).path
        }
        #expect(hub([:]) == "/home/someone/.cache/huggingface/hub")
        #expect(hub(["HF_HOME": "/data/hf"]) == "/data/hf/hub")
        #expect(hub(["HF_HOME": "/data/hf", "HF_HUB_CACHE": "/data/hub"]) == "/data/hub")
        #expect(hub(["XDG_CACHE_HOME": "/xdg"]) == "/xdg/huggingface/hub")
        #expect(hub(["HF_HOME": "  "]) == "/home/someone/.cache/huggingface/hub")
    }

    @Test("repository names split at the first double dash")
    func repositoryNames() {
        #expect(HuggingFaceCacheScanner.repository(fromFolderName: "models--org--name")?.repo == "name")
        #expect(HuggingFaceCacheScanner.repository(fromFolderName: "models--org--na--me")?.repo == "na--me")
        #expect(HuggingFaceCacheScanner.repository(fromFolderName: "datasets--org--name") == nil)
        #expect(HuggingFaceCacheScanner.repository(fromFolderName: "models--noorg") == nil)
    }

    // MARK: LM Studio

    @Test("LM Studio: publisher/repo folders with GGUF and MLX models")
    func lmStudio() throws {
        let root = try TemporaryDirectory()
        try root.file("lmstudio-community/Qwen3-4B-GGUF/Qwen3-4B-Q4_K_M.gguf", bytes: 300)
        try root.file("lmstudio-community/Qwen3-4B-GGUF/mmproj-Qwen3-4B-F16.gguf", bytes: 30)
        try root.file("mlx-community/Gemma-4-E2B-4bit/model.safetensors", bytes: 500)
        try root.file("mlx-community/Gemma-4-E2B-4bit/config.json", contents: mlxConfig)
        try root.file("nomic-ai/nomic-embed-text-v1.5-GGUF/nomic-embed-text-v1.5.Q4_K_M.gguf", bytes: 5)
        try root.file(".DS_Store")

        let entries = LMStudioScanner(modelsDirectory: root.url).scan()
        #expect(entries.count == 2)
        let gguf = try #require(entries.first { $0.kind == .gguf })
        #expect(gguf.source == .lmStudio)
        #expect(gguf.id == "lmstudio:lmstudio-community/Qwen3-4B-GGUF/Qwen3-4B-Q4_K_M.gguf")
        #expect(gguf.sizeBytes == 300)
        let mlx = try #require(entries.first { $0.kind == .mlx })
        #expect(mlx.id == "lmstudio:mlx-community/Gemma-4-E2B-4bit")
        #expect(mlx.sizeBytes == 500)
    }

    @Test("LM Studio folder missing is an empty list")
    func lmStudioMissing() throws {
        let root = try TemporaryDirectory()
        #expect(LMStudioScanner(modelsDirectory: root.url.appendingPathComponent("nope")).scan().isEmpty)
    }

    // MARK: User chosen

    @Test("a chosen .gguf file, an MLX folder and a folder of GGUF files")
    func userChosen() throws {
        let root = try TemporaryDirectory()
        let file = try root.file("anything.gguf", bytes: 77)
        _ = try root.file("my-mlx/model.safetensors", bytes: 40)
        let mlxFolder = try root.file("my-mlx/config.json", contents: #"{"model_type":"x"}"#).deletingLastPathComponent()
        _ = try root.file("shelf/a-Q5_K_M.gguf", bytes: 5)
        let shelf = root.url.appendingPathComponent("shelf")
        let notAModel = try root.file("notes.txt")

        let entries = UserChosenModelScanner(paths: [file, mlxFolder, shelf, notAModel, root.url.appendingPathComponent("gone")]).scan()
        #expect(entries.map(\.kind) == [.gguf, .mlx, .gguf])
        #expect(entries.allSatisfy { $0.source == .userChosen })
        #expect(entries[0].sizeBytes == 77)
        #expect(entries[1].spec.modelURL?.lastPathComponent == "my-mlx")
        #expect(entries[2].quantization == "Q5_K_M")
    }

    @Test("malformed shard names are skipped and never crash the scan")
    func malformedShardNames() throws {
        let root = try TemporaryDirectory()
        try root.file("pub/repo-GGUF/x-00001-of-00000.gguf", bytes: 5)
        try root.file("pub/repo-GGUF/x-00005-of-00003.gguf", bytes: 5)
        try root.file("pub/repo-GGUF/x-00000-of-00003.gguf", bytes: 5)
        try root.file("pub/repo-GGUF/x-00001-of-99999.gguf", bytes: 5)
        try root.file("pub/repo-GGUF/x-99999-of-99999.gguf", bytes: 5)
        try root.file("pub/repo-GGUF/x-1-of-3.gguf", bytes: 5)
        try root.file("pub/repo-GGUF/-00001-of-00001.gguf", bytes: 5)
        try root.file("pub/repo-GGUF/.gguf", bytes: 5)
        try root.file("pub/repo-GGUF/good-Q4_K_M.gguf", bytes: 7)

        let entries = LMStudioScanner(modelsDirectory: root.url).scan()
        // x-1-of-3 has no five-digit shard suffix, so it is an ordinary file name; a one-of-one shard is a real
        // split model whose name is only the suffix; the impossible shard numbers are gone.
        #expect(entries.map(\.displayName).sorted() == ["-00001-of-00001", "good-Q4_K_M", "x-1-of-3"])
    }

    @Test("shard parsing accepts only real numbers")
    func shardParsing() {
        #expect(ModelNameRules.ggufShard(fileName: "m-00002-of-00004.gguf")?.index == 2)
        #expect(ModelNameRules.ggufShard(fileName: "m-00001-of-00000.gguf") == nil)
        #expect(ModelNameRules.ggufShard(fileName: "m-00000-of-00004.gguf") == nil)
        #expect(ModelNameRules.ggufShard(fileName: "m-00005-of-00004.gguf") == nil)
        #expect(ModelNameRules.ggufShard(fileName: "m-00001-of-01000.gguf") == nil)
        #expect(ModelNameRules.hasShardSuffix(fileName: "m-00001-of-00000.gguf"))
        #expect(!ModelNameRules.hasShardSuffix(fileName: "m-Q4_K_M.gguf"))
    }

    @Test("odd file and folder names, empty files and broken configs do not crash the scan")
    func oddNames() throws {
        let root = try TemporaryDirectory()
        try root.file("pub/repo-GGUF/\u{202E}weird \u{1F4A5}.gguf", bytes: 0)
        try root.file("pub/repo-GGUF/spaces in name Q8_0.GGUF", bytes: 3)
        try root.file("mlx-community/broken-4bit/config.json", contents: "{not json")
        try root.file("mlx-community/broken-4bit/model.safetensors", bytes: 4)
        try root.file("mlx-community/emptycfg-4bit/config.json", contents: "")
        try root.file("mlx-community/emptycfg-4bit/model.safetensors", bytes: 4)
        try root.file("mlx-community/oddbits/config.json", contents: #"{"quantization":{"bits":"four"}}"#)
        try root.file("mlx-community/oddbits/model.safetensors", bytes: 4)
        let entries = LMStudioScanner(modelsDirectory: root.url).scan()
        #expect(entries.contains { $0.displayName == "spaces in name Q8_0" && $0.quantization == "Q8_0" })
        #expect(entries.filter { $0.kind == .mlx }.count == 3)
    }

    // MARK: Names

    @Test("quantization from file names")
    func quantizationNames() {
        func q(_ name: String) -> String? { ModelNameRules.ggufQuantization(fileName: name) }
        #expect(q("gemma-4-E2B-it-Q4_K_M.gguf") == "Q4_K_M")
        #expect(q("gemma-4-E2B-it-UD-Q4_K_XL.gguf") == "Q4_K_XL")
        #expect(q("nomic-embed-text-v1.5.f16.gguf") == "F16")
        #expect(q("model-IQ3_XS.gguf") == "IQ3_XS")
        #expect(q("llama.Q8_0.gguf") == "Q8_0")
        #expect(q("tinyllama.gguf") == nil)
    }
}
