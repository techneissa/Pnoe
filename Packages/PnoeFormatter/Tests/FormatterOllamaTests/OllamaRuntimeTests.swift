import FormatterCore
import Foundation
import Testing
@testable import FormatterOllama

@Suite("OllamaRuntime")
struct OllamaRuntimeTests {
    static let prefix = PromptPrefix(messages: [
        ChatMessage(role: .system, content: "rules"),
        ChatMessage(role: .user, content: "shot in"),
        ChatMessage(role: .assistant, content: "shot out"),
    ])

    static func reply(_ text: String, doneReason: String = "stop", done: Bool = true) -> Data {
        StubURLProtocol.json([
            "model": "gemma4:e2b", "done": done, "done_reason": doneReason,
            "message": ["role": "assistant", "content": text],
            "prompt_eval_count": 17, "eval_count": 9,
        ])
    }

    static func request(_ text: String = "hello there", cap: Int = 64, deadline: Duration = .seconds(5)) -> GenerationRequest {
        GenerationRequest(suffix: [ChatMessage(role: .user, content: text)], maxTokens: cap, deadline: .now + deadline)
    }

    static func runtime(
        warmUp: Bool = false, think: Bool? = nil, keepAlive: String = "10m", _ handler: @escaping StubURLProtocol.Handler
    ) -> (OllamaRuntime, String) {
        let (session, host) = StubURLProtocol.makeSession(handler)
        let configuration = OllamaRuntime.Configuration(keepAlive: keepAlive, think: think, warmUp: warmUp)
        return (OllamaRuntime(session: session, configuration: configuration), host)
    }

    static func spec(host: String) -> RuntimeModelSpec {
        RuntimeModelSpec(identifier: "gemma4:e2b", endpoint: URL(string: "http://\(host)")!, contextLength: 2048)
    }

    static func jsonObject(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: Request shape

    @Test func chatRequestCarriesModelPrefixSuffixAndOptions() async throws {
        let (runtime, host) = Self.runtime { _, _ in (200, Self.reply("Hello there.")) }
        try await runtime.prepare(Self.spec(host: host), prefix: Self.prefix)
        let result = try await runtime.generate(Self.request(cap: 77))

        let sent = try #require(StubURLProtocol.requests(for: host).first)
        #expect(sent.request.url?.path == "/api/chat")
        #expect(sent.request.httpMethod == "POST")
        let body = Self.jsonObject(sent.body)
        #expect(body["model"] as? String == "gemma4:e2b")
        #expect(body["stream"] as? Bool == false)
        #expect(body["keep_alive"] as? String == "10m")
        let options = try #require(body["options"] as? [String: Any])
        #expect(options["temperature"] as? Double == 0)
        #expect(options["num_predict"] as? Int == 77)
        #expect(options["num_ctx"] as? Int == 2048)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user", "assistant", "user"])
        #expect(messages.last?["content"] == "hello there")
        #expect(body["think"] == nil)
        #expect(result.text == "Hello there.")
        #expect(result.promptTokens == 17)
        #expect(result.generatedTokens == 9)
    }

    @Test func requestDeadlineBecomesTheURLTimeout() async throws {
        let (runtime, host) = Self.runtime { _, _ in (200, Self.reply("ok")) }
        try await runtime.prepare(Self.spec(host: host), prefix: Self.prefix)
        _ = try await runtime.generate(Self.request(deadline: .seconds(4)))
        let sent = try #require(StubURLProtocol.requests(for: host).first)
        #expect(sent.request.timeoutInterval > 3.0)
        #expect(sent.request.timeoutInterval <= 4.0)
    }

    @Test func keepAliveNumbersAreSentAsNumbers() async throws {
        let (runtime, host) = Self.runtime(keepAlive: "-1") { _, _ in (200, Self.reply("ok")) }
        try await runtime.prepare(Self.spec(host: host), prefix: Self.prefix)
        _ = try await runtime.generate(Self.request())
        let body = Self.jsonObject(try #require(StubURLProtocol.requests(for: host).first).body)
        #expect(body["keep_alive"] as? Int == -1)
    }

    @Test func thinkIsSentOnlyWhenSet() async throws {
        let (runtime, host) = Self.runtime(think: false) { _, _ in (200, Self.reply("ok")) }
        try await runtime.prepare(Self.spec(host: host), prefix: Self.prefix)
        _ = try await runtime.generate(Self.request())
        let body = Self.jsonObject(try #require(StubURLProtocol.requests(for: host).first).body)
        #expect(body["think"] as? Bool == false)
    }

    @Test func defaultEndpointIsLocalOllama() async throws {
        let (session, _) = StubURLProtocol.makeSession { _, _ in (200, Self.reply("ok")) }
        let runtime = OllamaRuntime(session: session, configuration: .init(warmUp: false))
        #expect(runtime.id == .ollama)
        #expect(OllamaRuntime.Configuration().defaultEndpoint.absoluteString == "http://localhost:11434")
    }

    // MARK: Warm-up

    @Test func prepareWarmsUpWithTheOneTokenRequest() async throws {
        let (runtime, host) = Self.runtime(warmUp: true) { _, _ in (200, Self.reply("ok")) }
        try await runtime.prepare(Self.spec(host: host), prefix: Self.prefix)
        let sent = StubURLProtocol.requests(for: host)
        #expect(sent.count == 1)
        let body = Self.jsonObject(sent[0].body)
        #expect((body["options"] as? [String: Any])?["num_predict"] as? Int == 1)
        #expect((body["messages"] as? [[String: String]])?.count == Self.prefix.messages.count + 1)
    }

    @Test func prepareWithoutWarmUpSendsNothing() async throws {
        let (runtime, host) = Self.runtime { _, _ in (200, Self.reply("ok")) }
        try await runtime.prepare(Self.spec(host: host), prefix: Self.prefix)
        #expect(StubURLProtocol.requests(for: host).isEmpty)
    }

    @Test func prepareReportsAMissingModel() async {
        let (runtime, host) = Self.runtime(warmUp: true) { _, _ in
            (404, StubURLProtocol.json(["error": "model 'gemma4:e2b' not found"]))
        }
        await #expect(throws: FormatterRuntimeError.notReady) {
            try await runtime.prepare(Self.spec(host: host), prefix: Self.prefix)
        }
    }

    // MARK: Stop reasons

    @Test func normalEndIsEos() async throws {
        let (runtime, host) = Self.runtime { _, _ in (200, Self.reply("Done.")) }
        try await runtime.prepare(Self.spec(host: host), prefix: Self.prefix)
        #expect(try await runtime.generate(Self.request()).stopReason == .eos)
    }

    @Test func lengthIsACapHit() async throws {
        let (runtime, host) = Self.runtime { _, _ in (200, Self.reply("Cut off mid", doneReason: "length")) }
        try await runtime.prepare(Self.spec(host: host), prefix: Self.prefix)
        let result = try await runtime.generate(Self.request())
        #expect(result.stopReason == .cap)
        #expect(result.text == "Cut off mid")
    }

    @Test func anUnfinishedResponseIsInterrupted() async throws {
        let (runtime, host) = Self.runtime { _, _ in (200, Self.reply("partial", done: false)) }
        try await runtime.prepare(Self.spec(host: host), prefix: Self.prefix)
        #expect(try await runtime.generate(Self.request()).stopReason == .interrupted)
    }

    @Test func aTimeoutIsInterruptedWithNoText() async throws {
        let (runtime, host) = Self.runtime { _, _ in throw URLError(.timedOut) }
        try await runtime.prepare(Self.spec(host: host), prefix: Self.prefix)
        let result = try await runtime.generate(Self.request())
        #expect(result.stopReason == .interrupted)
        #expect(result.text.isEmpty)
    }

    @Test func cancelEndsARunningRequestAsInterrupted() async throws {
        // A server that never answers; the request ends only when the client cancels.
        let (runtime, host) = Self.runtime { _, _ in nil }
        try await runtime.prepare(Self.spec(host: host), prefix: Self.prefix)
        let request = Self.request(deadline: .seconds(30))
        let pending = Task { try await runtime.generate(request) }
        while StubURLProtocol.requests(for: host).isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        await runtime.cancel(request.id)
        let result = try await pending.value
        #expect(result.stopReason == .interrupted)
    }

    @Test func cancelBeforeTheRequestStartsReturnsAtOnce() async throws {
        let (runtime, host) = Self.runtime { _, _ in (200, Self.reply("never sent")) }
        try await runtime.prepare(Self.spec(host: host), prefix: Self.prefix)
        let request = Self.request()
        await runtime.cancel(request.id)
        #expect(try await runtime.generate(request).stopReason == .interrupted)
        #expect(StubURLProtocol.requests(for: host).isEmpty)
    }

    // MARK: Errors

    @Test func generateBeforePrepareIsNotReady() async {
        let (runtime, _) = Self.runtime { _, _ in (200, Self.reply("ok")) }
        await #expect(throws: FormatterRuntimeError.notReady) { try await runtime.generate(Self.request()) }
    }

    @Test func noServerIsNotReady() async throws {
        let (runtime, host) = Self.runtime { _, _ in throw URLError(.cannotConnectToHost) }
        try await runtime.prepare(Self.spec(host: host), prefix: Self.prefix)
        await #expect(throws: FormatterRuntimeError.notReady) { try await runtime.generate(Self.request()) }
    }

    @Test func serverErrorsCarryTheMessage() async throws {
        let (runtime, host) = Self.runtime { _, _ in (500, StubURLProtocol.json(["error": "out of memory"])) }
        try await runtime.prepare(Self.spec(host: host), prefix: Self.prefix)
        await #expect(throws: FormatterRuntimeError.failed("HTTP 500: out of memory")) { try await runtime.generate(Self.request()) }
    }

    @Test func garbageIsAFailureNotACrash() async throws {
        let (runtime, host) = Self.runtime { _, _ in (200, Data("not json".utf8)) }
        try await runtime.prepare(Self.spec(host: host), prefix: Self.prefix)
        await #expect(throws: FormatterRuntimeError.failed("unreadable response")) { try await runtime.generate(Self.request()) }
    }

    // MARK: Unload and pipeline

    @Test func unloadAsksOllamaToDropTheModel() async throws {
        let (runtime, host) = Self.runtime { _, _ in (200, Self.reply("")) }
        try await runtime.prepare(Self.spec(host: host), prefix: Self.prefix)
        await runtime.unload()
        let body = Self.jsonObject(try #require(StubURLProtocol.requests(for: host).last).body)
        #expect(body["keep_alive"] as? Int == 0)
        await #expect(throws: FormatterRuntimeError.notReady) { try await runtime.generate(Self.request()) }
    }

    @Test func runsInsideThePipeline() async throws {
        let (runtime, host) = Self.runtime { _, _ in
            (200, Self.reply("Please send the report by Friday, thanks."))
        }
        let pipeline = try FormatterPipeline.bundled(runtime: runtime)
        try await runtime.prepare(Self.spec(host: host), prefix: pipeline.prefix)
        let outcome = await pipeline.format("please send the report by friday thanks", context: .chat)
        #expect(outcome == .formatted("Please send the report by Friday, thanks."))
    }

    @Test func aCapHitFallsBackToRawInThePipeline() async throws {
        let (runtime, host) = Self.runtime { _, _ in (200, Self.reply("Please send the", doneReason: "length")) }
        let pipeline = try FormatterPipeline.bundled(runtime: runtime)
        try await runtime.prepare(Self.spec(host: host), prefix: pipeline.prefix)
        let outcome = await pipeline.format("please send the report by friday thanks", context: .chat)
        #expect(outcome.reason == .truncated)
    }
}
