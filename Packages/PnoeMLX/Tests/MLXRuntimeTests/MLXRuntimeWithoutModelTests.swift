import FormatterCore
import XCTest

@testable import MLXRuntime

/// What the runtime does before any model is loaded. No model is read and no MLX array is made.
final class MLXRuntimeWithoutModelTests: XCTestCase {
    private let prefix = PromptPrefix(messages: [ChatMessage(role: .system, content: "Fix punctuation.")])

    func testItIsTheMLXRuntime() {
        XCTAssertEqual(MLXRuntime().id, .mlx)
    }

    func testAMissingFolderIsNotReady() async {
        let runtime = MLXRuntime()
        let spec = RuntimeModelSpec(modelURL: URL(fileURLWithPath: "/nonexistent/mlx-model"), backend: .mlx)
        do {
            try await runtime.prepare(spec, prefix: prefix)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? FormatterRuntimeError, .notReady)
        }
    }

    func testASpecWithoutAFolderFails() async {
        let runtime = MLXRuntime()
        do {
            try await runtime.prepare(RuntimeModelSpec(identifier: "gemma4:e2b"), prefix: prefix)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? FormatterRuntimeError, .failed("the model has no folder"))
        }
    }

    func testAFolderWithoutAChatTemplateFails() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let runtime = MLXRuntime()
        do {
            try await runtime.prepare(RuntimeModelSpec(modelURL: folder, backend: .mlx), prefix: prefix)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? FormatterRuntimeError, .failed("the model has no chat template"))
        }
    }

    func testGenerateBeforePrepareIsNotReady() async {
        let request = GenerationRequest(
            suffix: [ChatMessage(role: .user, content: "hello")], maxTokens: 16, deadline: .now + .seconds(5))
        do {
            _ = try await MLXRuntime().generate(request)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? FormatterRuntimeError, .notReady)
        }
    }

    func testUnloadWithoutAModelIsHarmless() async {
        await MLXRuntime().unload()
    }
}
