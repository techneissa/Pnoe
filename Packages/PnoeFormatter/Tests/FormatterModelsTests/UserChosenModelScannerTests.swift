import Foundation
import Testing
@testable import FormatterModels

@Suite("UserChosenModelScanner")
struct UserChosenModelScannerTests {
    private func scan(_ folder: URL) -> [FormatterModelEntry] {
        UserChosenModelScanner(paths: [folder]).scan()
    }

    @Test("a folder with a quantized config and safetensors is an MLX model, whatever its name")
    func quantizedFolder() throws {
        let home = try TemporaryDirectory()
        try home.file("anything/config.json", contents: #"{"quantization":{"bits":4}}"#)
        try home.file("anything/model.safetensors", bytes: 30)
        let entries = scan(home.url.appendingPathComponent("anything"))
        #expect(entries.count == 1)
        #expect(entries.first?.kind == .mlx)
        #expect(entries.first?.spec.backend == .mlx)
        #expect(entries.first?.quantization == "4bit")
    }

    @Test("an MLX or bit-width name is enough without a quantization entry")
    func namedFolder() throws {
        let home = try TemporaryDirectory()
        try home.file("Phi-4-mlx/config.json", contents: "{}")
        try home.file("Phi-4-mlx/model.safetensors", bytes: 30)
        try home.file("llama-8bit/config.json", contents: "{}")
        try home.file("llama-8bit/model.safetensors", bytes: 30)
        #expect(scan(home.url.appendingPathComponent("Phi-4-mlx")).map(\.kind) == [.mlx])
        #expect(scan(home.url.appendingPathComponent("llama-8bit")).map(\.kind) == [.mlx])
    }

    @Test("a plain Hugging Face checkpoint (config.json and safetensors, no MLX sign) is not listed as MLX")
    func plainCheckpoint() throws {
        let home = try TemporaryDirectory()
        try home.file("Qwen3-4B/config.json", contents: #"{"model_type":"qwen3","torch_dtype":"bfloat16"}"#)
        try home.file("Qwen3-4B/model.safetensors", bytes: 30)
        #expect(scan(home.url.appendingPathComponent("Qwen3-4B")).isEmpty)
    }

    @Test("a folder with exactly one GGUF lists that file, a folder with nothing lists nothing")
    func ggufFolderAndEmptyFolder() throws {
        let home = try TemporaryDirectory()
        try home.file("one/model-Q4_K_M.gguf", bytes: 30)
        try home.file("empty/readme.txt", bytes: 3)
        let one = scan(home.url.appendingPathComponent("one"))
        #expect(one.map(\.kind) == [.gguf])
        #expect(scan(home.url.appendingPathComponent("empty")).isEmpty)
    }
}
