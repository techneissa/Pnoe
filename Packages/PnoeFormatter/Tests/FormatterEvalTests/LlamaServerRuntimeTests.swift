import FormatterCore
import Foundation
import Testing
@testable import FormatterEvalKit

@Suite("LlamaServerRuntime")
struct LlamaServerRuntimeTests {
    static let prefix = PromptPrefix(messages: [ChatMessage(role: .system, content: "rules")])

    static func reply(_ text: String, finish: String = "stop") -> Data {
        StubURLProtocol.json([
            "choices": [["message": ["role": "assistant", "content": text], "finish_reason": finish]],
            "usage": ["prompt_tokens": 120, "completion_tokens": 7],
            "timings": ["prompt_n": 14, "cache_n": 106],
        ])
    }

    static func make(
        warmUp: Bool = false, thinking: Bool? = nil, _ handler: @escaping StubURLProtocol.Handler
    ) -> (LlamaServerRuntime, RuntimeModelSpec, String) {
        let (session, host) = StubURLProtocol.makeSession(handler)
        let runtime = LlamaServerRuntime(session: session, configuration: .init(enableThinking: thinking, warmUp: warmUp))
        return (runtime, RuntimeModelSpec(identifier: "gemma-4-E2B", endpoint: URL(string: "http://\(host)")!), host)
    }

    static func request(cap: Int = 50) -> GenerationRequest {
        GenerationRequest(suffix: [ChatMessage(role: .user, content: "hi there")], maxTokens: cap, deadline: .now + .seconds(5))
    }

    static func body(_ host: String) throws -> [String: Any] {
        let last = try #require(StubURLProtocol.requests(for: host).last)
        return try #require(JSONSerialization.jsonObject(with: last.body) as? [String: Any])
    }

    @Test func postsAnOpenAIChatRequestWithTemperatureZero() async throws {
        let (runtime, spec, host) = Self.make { _, _ in (200, Self.reply("Hi there.")) }
        try await runtime.prepare(spec, prefix: Self.prefix)
        let result = try await runtime.generate(Self.request(cap: 33))
        let sent = try #require(StubURLProtocol.requests(for: host).first)
        #expect(sent.request.url?.path == "/v1/chat/completions")
        let body = try Self.body(host)
        #expect(body["model"] as? String == "gemma-4-E2B")
        #expect(body["temperature"] as? Double == 0)
        #expect(body["max_tokens"] as? Int == 33)
        #expect(body["stream"] as? Bool == false)
        #expect(body["cache_prompt"] as? Bool == true)
        #expect((body["messages"] as? [[String: String]])?.map { $0["role"] } == ["system", "user"])
        #expect(result.text == "Hi there.")
        #expect(result.stopReason == .eos)
        // The count after the prompt cache, not the whole prompt.
        #expect(result.promptTokens == 14)
        #expect(result.generatedTokens == 7)
        #expect(runtime.id == .llama)
    }

    @Test func lengthIsACapHit() async throws {
        let (runtime, spec, _) = Self.make { _, _ in (200, Self.reply("cut", finish: "length")) }
        try await runtime.prepare(spec, prefix: Self.prefix)
        #expect(try await runtime.generate(Self.request()).stopReason == .cap)
    }

    @Test func thinkingCanBeTurnedOff() async throws {
        let (runtime, spec, host) = Self.make(thinking: false) { _, _ in (200, Self.reply("ok")) }
        try await runtime.prepare(spec, prefix: Self.prefix)
        _ = try await runtime.generate(Self.request())
        let kwargs = try #require(try Self.body(host)["chat_template_kwargs"] as? [String: Bool])
        #expect(kwargs["enable_thinking"] == false)
    }

    @Test func warmUpSendsOneTokenRequest() async throws {
        let (runtime, spec, host) = Self.make(warmUp: true) { _, _ in (200, Self.reply("ok")) }
        try await runtime.prepare(spec, prefix: Self.prefix)
        #expect(StubURLProtocol.requests(for: host).count == 1)
        #expect(try Self.body(host)["max_tokens"] as? Int == 1)
    }

    @Test func aLoadingServerIsReportedAsLoading() async throws {
        let (runtime, spec, _) = Self.make { _, _ in (503, Data("{\"error\":{\"message\":\"Loading model\"}}".utf8)) }
        try await runtime.prepare(spec, prefix: Self.prefix)
        await #expect(throws: FormatterRuntimeError.modelLoading) { try await runtime.generate(Self.request()) }
    }

    @Test func noServerIsNotReady() async throws {
        let (runtime, spec, _) = Self.make { _, _ in throw URLError(.cannotConnectToHost) }
        try await runtime.prepare(spec, prefix: Self.prefix)
        await #expect(throws: FormatterRuntimeError.notReady) { try await runtime.generate(Self.request()) }
    }

    @Test func aTimeoutIsInterrupted() async throws {
        let (runtime, spec, _) = Self.make { _, _ in throw URLError(.timedOut) }
        try await runtime.prepare(spec, prefix: Self.prefix)
        let result = try await runtime.generate(Self.request())
        #expect(result.stopReason == .interrupted)
    }

    @Test func cancelEndsAHungRequest() async throws {
        let (runtime, spec, host) = Self.make { _, _ in nil }
        try await runtime.prepare(spec, prefix: Self.prefix)
        let request = Self.request()
        let pending = Task { try await runtime.generate(request) }
        while StubURLProtocol.requests(for: host).isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        await runtime.cancel(request.id)
        #expect(try await pending.value.stopReason == .interrupted)
    }

    @Test func unreadableBodiesAreFailures() async throws {
        let (runtime, spec, _) = Self.make { _, _ in (200, Data("{}".utf8)) }
        try await runtime.prepare(spec, prefix: Self.prefix)
        await #expect(throws: FormatterRuntimeError.failed("unreadable response")) { try await runtime.generate(Self.request()) }
    }

    @Test func evalRunnerWorksOverHTTP() async throws {
        let cases = [Fixtures.testCase("r1-n3")]
        let (runtime, spec, _) = Self.make { _, _ in (200, Self.reply("Idea for the app: let users pin their favorite modes to the menu bar.")) }
        let builder = try PromptBuilder.bundled()
        try await runtime.prepare(spec, prefix: FormatterPipeline(runtime: runtime, promptBuilder: builder).prefix)
        let results = await EvalRunner.run(cases: cases, runtime: runtime, promptBuilder: builder)
        #expect(results[0].outcome == "formatted")
        #expect(results[0].pipeline.looseMatch)
    }
}
