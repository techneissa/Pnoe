import FormatterCore
import Foundation
import Testing
@testable import FormatterModels

@Suite("LocalModelPreselection")
struct LocalModelPreselectionTests {
    private func ollama(_ name: String, gigabytes: Double?) -> FormatterModelEntry {
        FormatterModelEntry(
            id: "ollama:\(name)",
            displayName: name,
            kind: .ollama,
            sizeBytes: gigabytes.map { Int64($0 * 1_000_000_000) },
            source: .ollama,
            spec: RuntimeModelSpec(identifier: name)
        )
    }

    @Test("picks the smallest Gemma or Qwen instruct model")
    func smallest() {
        let entries = [
            ollama("gemma3:12b", gigabytes: 8.1),
            ollama("qwen3:4b", gigabytes: 2.5),
            ollama("gemma3:4b", gigabytes: 3.3),
            ollama("llama3.2:1b", gigabytes: 1.3),
        ]
        #expect(LocalModelPreselection.choose(from: entries)?.displayName == "qwen3:4b")
    }

    @Test("skips base, code, vision and tiny models, and other families")
    func skipsUnsuitable() {
        let entries = [
            ollama("gemma3:4b-pt", gigabytes: 3.0),
            ollama("gemma3:4b-text", gigabytes: 3.0),
            ollama("qwen2.5-coder:7b", gigabytes: 4.7),
            ollama("qwen2.5vl:3b", gigabytes: 3.2),
            ollama("qwen3:0.6b", gigabytes: 0.5),
            ollama("mistral:7b", gigabytes: 4.1),
            ollama("qwen3:8b", gigabytes: 5.2),
        ]
        #expect(LocalModelPreselection.choose(from: entries)?.displayName == "qwen3:8b")
    }

    @Test("nothing qualifies when Ollama has no such model or is not running")
    func none() {
        #expect(LocalModelPreselection.choose(from: []) == nil)
        #expect(LocalModelPreselection.choose(from: [ollama("llama3.2:3b", gigabytes: 2)]) == nil)
    }

    @Test("files from other sources are never preselected")
    func ollamaOnly() {
        let file = FormatterModelEntry(
            id: "hf:gemma", displayName: "gemma-4-E2B-it-Q4_K_M.gguf", kind: .gguf, sizeBytes: 3_000_000_000,
            source: .huggingFaceCache, spec: RuntimeModelSpec(identifier: "gemma"))
        #expect(LocalModelPreselection.choose(from: [file]) == nil)
    }

    @Test("a fake discovery decides: the choice comes from what it returns")
    func fakeDiscovery() async {
        let chosen = await LocalModelPreselection.choose {
            [self.ollama("gemma3:4b", gigabytes: 3.3), self.ollama("gemma3:1b", gigabytes: 0.8)]
        }
        #expect(chosen?.displayName == "gemma3:4b")
        let empty = await LocalModelPreselection.choose { [] }
        #expect(empty == nil)
    }
}
