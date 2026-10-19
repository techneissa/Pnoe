import FormatterCore
import Foundation
import Testing
@testable import LlamaRuntime

/// What the runtime does when there is no usable model. These load no model: they use a missing path and a
/// file that is not a GGUF.
@Suite("LlamaRuntime without a model")
struct LlamaRuntimeWithoutModelTests {
    static let prefix = PromptPrefix(messages: [ChatMessage(role: .system, content: "rules")])

    static func request() -> GenerationRequest {
        GenerationRequest(suffix: [ChatMessage(role: .user, content: "hello")], maxTokens: 8, deadline: .now + .seconds(2))
    }

    @Test func generateBeforePrepareIsNotReady() async {
        let runtime = LlamaRuntime()
        await #expect(throws: FormatterRuntimeError.notReady) { try await runtime.generate(Self.request()) }
    }

    @Test func aMissingFileIsNotReady() async {
        let runtime = LlamaRuntime()
        let spec = RuntimeModelSpec(modelURL: URL(fileURLWithPath: "/nonexistent/model.gguf"))
        await #expect(throws: FormatterRuntimeError.notReady) { try await runtime.prepare(spec, prefix: Self.prefix) }
    }

    @Test func aSpecWithoutAFileIsAFailure() async {
        let runtime = LlamaRuntime()
        await #expect(throws: FormatterRuntimeError.failed("the model has no file")) {
            try await runtime.prepare(RuntimeModelSpec(identifier: "gemma4:e2b"), prefix: Self.prefix)
        }
    }

    @Test func aFileThatIsNotAModelFailsToLoadAndLeavesTheRuntimeNotReady() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-model-\(UUID().uuidString).gguf")
        try Data("this is not a GGUF file".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let runtime = LlamaRuntime()
        await #expect(throws: FormatterRuntimeError.failed("the model file could not be loaded")) {
            try await runtime.prepare(RuntimeModelSpec(modelURL: file), prefix: Self.prefix)
        }
        await #expect(throws: FormatterRuntimeError.notReady) { try await runtime.generate(Self.request()) }
    }

    @Test func unloadAndCancelAreSafeWithNothingLoaded() async {
        let runtime = LlamaRuntime()
        await runtime.cancel(UUID())
        await runtime.unload()
        await runtime.unload()
    }
}
