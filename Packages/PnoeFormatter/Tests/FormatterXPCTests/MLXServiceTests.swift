import FormatterCore
import Foundation
import Testing
@testable import FormatterXPC

/// The two services side by side: each has its own loopback and its own scripted runtime, behind the router the
/// Built-in engine uses. A GGUF spec must reach the llama service and an MLX spec the MLX service, with the same
/// protocol, deadline, crash and unload behaviour on both.
@Suite("MLX service next to the llama service")
struct MLXServiceTests {
    static let prefix = PromptPrefix(messages: [
        ChatMessage(role: .system, content: "rules"),
        ChatMessage(role: .user, content: "shot in"),
        ChatMessage(role: .assistant, content: "shot out"),
    ])
    static let gguf = RuntimeModelSpec(
        identifier: "gemma-4-E2B-it-Q4_K_M", modelURL: URL(fileURLWithPath: "/models/gemma-4-E2B-it-Q4_K_M.gguf"))
    static let mlx = RuntimeModelSpec(
        identifier: "gemma-4-e2b-it-4bit", modelURL: URL(fileURLWithPath: "/models/gemma-4-e2b-it-4bit"), backend: .mlx)

    struct Rig {
        let llamaService = ScriptedRuntime()
        let mlxService = ScriptedRuntime()
        let llamaLoopback: Loopback
        let mlxLoopback: Loopback
        let llama: XPCFormatterRuntime
        let mlx: XPCFormatterRuntime
        let router: RoutingFormatterRuntime

        init(configuration: XPCFormatterRuntime.Configuration = .init()) {
            llamaLoopback = Loopback(runtime: llamaService)
            mlxLoopback = Loopback(runtime: mlxService)
            llama = llamaLoopback.client(configuration, id: .llama)
            mlx = mlxLoopback.client(configuration, id: .mlx)
            router = RoutingFormatterRuntime(backends: [.llama: llama, .mlx: mlx], fallback: .llama)
        }
    }

    static func request(_ text: String = "hello there") -> GenerationRequest {
        GenerationRequest(
            suffix: [ChatMessage(role: .user, content: text)], maxTokens: 64, deadline: .now + .seconds(5),
            prefixKey: prefix.key)
    }

    @Test func theMLXClientIsTheMLXRuntime() {
        let rig = Rig()
        #expect(rig.mlx.id == .mlx)
        #expect(rig.llama.id == .llama)
    }

    @Test func theMLXServiceHasItsOwnName() {
        #expect(mlxFormatterXPCServiceName == "com.techneissa.Pnoe.PnoeFormatterMLXXPC")
        #expect(mlxFormatterXPCServiceName != formatterXPCServiceName)
    }

    @Test func anMLXModelRunsOnTheMLXServiceOnly() async throws {
        let rig = Rig()
        await rig.mlxService.setReply(GenerationResult(text: "from mlx", stopReason: .eos, promptTokens: 9, generatedTokens: 4))
        try await rig.router.prepare(Self.mlx, prefix: Self.prefix)
        let result = try await rig.router.generate(Self.request())

        #expect(result.text == "from mlx")
        #expect(await rig.mlxService.prepareCalls.count == 1)
        // The folder crosses the process; the routing hint stays in the app.
        #expect(await rig.mlxService.prepareCalls.first?.0.modelURL == Self.mlx.modelURL)
        #expect(await rig.mlxService.requests.count == 1)
        #expect(await rig.llamaService.prepareCalls.isEmpty)
        #expect(await rig.llamaService.requests.isEmpty)
    }

    @Test func aGGUFModelRunsOnTheLlamaServiceOnly() async throws {
        let rig = Rig()
        await rig.llamaService.setReply(GenerationResult(text: "from llama", stopReason: .eos))
        try await rig.router.prepare(Self.gguf, prefix: Self.prefix)
        let result = try await rig.router.generate(Self.request())

        #expect(result.text == "from llama")
        #expect(await rig.llamaService.requests.count == 1)
        #expect(await rig.mlxService.prepareCalls.isEmpty)
        #expect(await rig.mlxService.requests.isEmpty)
    }

    @Test func switchingModelsMovesTheNextTakeToTheOtherService() async throws {
        let rig = Rig()
        await rig.llamaService.setReply(GenerationResult(text: "llama", stopReason: .eos))
        await rig.mlxService.setReply(GenerationResult(text: "mlx", stopReason: .eos))
        try await rig.router.prepare(Self.gguf, prefix: Self.prefix)
        #expect(try await rig.router.generate(Self.request()).text == "llama")
        try await rig.router.prepare(Self.mlx, prefix: Self.prefix)
        #expect(try await rig.router.generate(Self.request()).text == "mlx")
        // Back on the first model: its service still has it loaded, so nothing is prepared again.
        try await rig.router.prepare(Self.gguf, prefix: Self.prefix)
        #expect(try await rig.router.generate(Self.request()).text == "llama")
        #expect(await rig.llamaService.prepareCalls.count == 1)
    }

    @Test func unloadReachesBothServices() async throws {
        let rig = Rig()
        try await rig.router.prepare(Self.gguf, prefix: Self.prefix)
        try await rig.router.prepare(Self.mlx, prefix: Self.prefix)
        await rig.router.unload()
        #expect(await rig.llamaService.unloadCount >= 1)
        #expect(await rig.mlxService.unloadCount >= 1)
    }

    @Test func anMLXServiceCrashIsThatTakesFallbackAndLeavesTheLlamaServiceAlone() async throws {
        let rig = Rig()
        try await rig.router.prepare(Self.gguf, prefix: Self.prefix)
        try await rig.router.prepare(Self.mlx, prefix: Self.prefix)
        await rig.mlxService.hold()

        let take = Task { try await rig.router.generate(Self.request()) }
        for _ in 0..<200 where await rig.mlxService.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        rig.mlxLoopback.killService()
        await #expect(throws: FormatterRuntimeError.crashed) { try await take.value }
        await rig.mlxService.release()

        // The llama service never noticed: a take on the GGUF model still works, with no new prepare.
        try await rig.router.prepare(Self.gguf, prefix: Self.prefix)
        #expect(try await rig.router.generate(Self.request()).text == "ok")
        #expect(await rig.llamaService.prepareCalls.count == 1)
        #expect(rig.llamaLoopback.lastConnectionClosedCount == 0)
    }

    @Test func threeMLXCrashesStopMLXRestartsButNotTheGGUFModel() async throws {
        var configuration = XPCFormatterRuntime.Configuration()
        configuration.crashLimit = 3
        let rig = Rig(configuration: configuration)
        for _ in 0..<3 {
            try await rig.router.prepare(Self.mlx, prefix: Self.prefix)
            await rig.mlxService.hold()
            let take = Task { try await rig.router.generate(Self.request()) }
            for _ in 0..<200 where await rig.mlxService.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            rig.mlxLoopback.killService()
            await #expect(throws: FormatterRuntimeError.crashed) { try await take.value }
            await rig.mlxService.release()
            await rig.mlxService.clearRequests()
        }
        await #expect(throws: FormatterRuntimeError.crashed) { try await rig.router.prepare(Self.mlx, prefix: Self.prefix) }
        try await rig.router.prepare(Self.gguf, prefix: Self.prefix)
        #expect(try await rig.router.generate(Self.request()).text == "ok")
    }
}
