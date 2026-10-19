import XCTest

@testable import FormatterCore

final class RoutingRuntimeTests: XCTestCase {
    private let prefix = PromptPrefix(messages: [ChatMessage(role: .system, content: "rules")])
    private let otherPrefix = PromptPrefix(messages: [ChatMessage(role: .system, content: "other rules")])
    private let gguf = RuntimeModelSpec(modelURL: URL(fileURLWithPath: "/models/gemma-4-E2B-it-Q4_K_M.gguf"))
    private let mlx = RuntimeModelSpec(modelURL: URL(fileURLWithPath: "/models/gemma-4-e2b-it-4bit"), backend: .mlx)

    private func rig() -> (RoutingFormatterRuntime, FakeRuntime, FakeRuntime) {
        let llama = FakeRuntime(id: .llama, handler: { _ in GenerationResult(text: "llama") })
        let mlxRuntime = FakeRuntime(id: .mlx, handler: { _ in GenerationResult(text: "mlx") })
        return (RoutingFormatterRuntime(backends: [.llama: llama, .mlx: mlxRuntime], fallback: .llama), llama, mlxRuntime)
    }

    private func request(_ prefix: PromptPrefix) -> GenerationRequest {
        GenerationRequest(
            suffix: [ChatMessage(role: .user, content: "hi")], maxTokens: 8, deadline: .now + .seconds(5),
            prefixKey: prefix.key)
    }

    func testASpecWithoutABackendGoesToTheFallback() {
        let (router, _, _) = rig()
        XCTAssertEqual(router.backend(for: gguf), .llama)
        XCTAssertEqual(router.backend(for: mlx), .mlx)
        XCTAssertEqual(router.backend(for: RuntimeModelSpec(identifier: "x", backend: .ollama)), .llama)
    }

    func testPrepareAndGenerateFollowTheModel() async throws {
        let (router, llama, mlxRuntime) = rig()
        try await router.prepare(mlx, prefix: prefix)
        let result = try await router.generate(request(prefix))
        XCTAssertEqual(result.text, "mlx")
        let llamaPrepares = await llama.prepareCalls.count
        let mlxPrepares = await mlxRuntime.prepareCalls.count
        XCTAssertEqual(llamaPrepares, 0)
        XCTAssertEqual(mlxPrepares, 1)
    }

    func testARequestFindsTheBackendItsPrefixWasPreparedOn() async throws {
        let (router, _, _) = rig()
        try await router.prepare(gguf, prefix: prefix)
        try await router.prepare(mlx, prefix: otherPrefix)
        // A workflow on the other backend prepared in between; this request still goes where its prefix went.
        let first = try await router.generate(request(prefix))
        XCTAssertEqual(first.text, "llama")
        let second = try await router.generate(request(otherPrefix))
        XCTAssertEqual(second.text, "mlx")
    }

    func testARequestWithoutAPrefixKeyGoesToTheLastPreparedBackend() async throws {
        let (router, _, _) = rig()
        try await router.prepare(gguf, prefix: prefix)
        try await router.prepare(mlx, prefix: prefix)
        var bare = request(prefix)
        bare.prefixKey = nil
        let result = try await router.generate(bare)
        XCTAssertEqual(result.text, "mlx")
    }

    func testDeadlinePrepareIsRoutedToo() async throws {
        let (router, llama, mlxRuntime) = rig()
        try await router.prepare(mlx, prefix: prefix, deadline: .now + .seconds(3))
        let llamaPrepares = await llama.prepareCalls.count
        let mlxPrepares = await mlxRuntime.prepareCalls.count
        XCTAssertEqual(llamaPrepares, 0)
        XCTAssertEqual(mlxPrepares, 1)
    }

    func testUnloadAndCancelReachEveryBackend() async throws {
        let (router, llama, mlxRuntime) = rig()
        let id = UUID()
        await router.cancel(id)
        await router.unload()
        let cancelledLlama = await llama.cancelled
        let cancelledMLX = await mlxRuntime.cancelled
        let unloadedLlama = await llama.unloadCount
        let unloadedMLX = await mlxRuntime.unloadCount
        XCTAssertEqual(cancelledLlama, [id])
        XCTAssertEqual(cancelledMLX, [id])
        XCTAssertEqual(unloadedLlama, 1)
        XCTAssertEqual(unloadedMLX, 1)
    }

    func testAPrepareErrorComesBackUnchanged() async {
        let failing = FakeRuntime(id: .mlx, prepareError: .failed("no template"), handler: { _ in GenerationResult(text: "") })
        let router = RoutingFormatterRuntime(
            backends: [.llama: FakeRuntime(returning: "x"), .mlx: failing], fallback: .llama)
        do {
            try await router.prepare(mlx, prefix: prefix)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? FormatterRuntimeError, .failed("no template"))
        }
    }
}
