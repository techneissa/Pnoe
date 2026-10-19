import FormatterCore
import Foundation
import Testing
@testable import FormatterXPC

@Suite("XPCFormatterRuntime over a loopback connection")
struct XPCFormatterRuntimeTests {
    static let prefix = PromptPrefix(messages: [
        ChatMessage(role: .system, content: "rules"),
        ChatMessage(role: .user, content: "shot in"),
        ChatMessage(role: .assistant, content: "shot out"),
    ])
    static let spec = RuntimeModelSpec(
        identifier: "gemma-4-E2B-it-Q4_K_M", modelURL: URL(fileURLWithPath: "/models/gemma-4-E2B-it-Q4_K_M.gguf"),
        contextLength: 4096)

    static func request(cap: Int = 64, deadline: Duration = .seconds(5)) -> GenerationRequest {
        GenerationRequest(
            suffix: [ChatMessage(role: .user, content: "hello there")], maxTokens: cap, deadline: .now + deadline)
    }

    static func ready(
        _ runtime: ScriptedRuntime = ScriptedRuntime(), _ configuration: XPCFormatterRuntime.Configuration = .init()
    ) async throws -> (Loopback, XPCFormatterRuntime, ScriptedRuntime) {
        let loopback = Loopback(runtime: runtime)
        let client = loopback.client(configuration)
        try await client.prepare(spec, prefix: prefix)
        return (loopback, client, runtime)
    }

    // MARK: Round trip

    @Test func prepareSendsTheModelAndThePrefixAndGenerateReturnsTheResult() async throws {
        let (_, client, service) = try await Self.ready()
        let prepared = await service.prepareCalls
        #expect(prepared.count == 1)
        #expect(prepared[0].0 == Self.spec)
        #expect(prepared[0].1 == Self.prefix)

        let request = Self.request(cap: 77)
        let result = try await client.generate(request)
        #expect(result == GenerationResult(text: "ok", stopReason: .eos, promptTokens: 12, generatedTokens: 3))

        let seen = try #require(await service.requests.first)
        #expect(seen.id == request.id)
        #expect(seen.suffix == request.suffix)
        #expect(seen.maxTokens == 77)
        #expect(seen.temperature == 0)
        // The deadline crosses the process as seconds left, and is rebuilt on the other side.
        #expect(seen.deadline <= .now + .seconds(5))
        #expect(seen.deadline > .now)
    }

    @Test func stopReasonsTravelUnchanged() async throws {
        let (_, client, service) = try await Self.ready()
        for reason in [StopReason.cap, .interrupted, .eos] {
            await service.setReply(GenerationResult(text: "partial", stopReason: reason, promptTokens: 1, generatedTokens: 2))
            let result = try await client.generate(Self.request())
            #expect(result.stopReason == reason)
            #expect(result.text == "partial")
        }
    }

    @Test func aSecondPrepareWithTheSameModelAndPrefixDoesNotReloadIt() async throws {
        let (_, client, service) = try await Self.ready()
        try await client.prepare(Self.spec, prefix: Self.prefix)
        #expect(await service.prepareCalls.count == 1)

        var other = Self.spec
        other.identifier = "other"
        try await client.prepare(other, prefix: Self.prefix)
        #expect(await service.prepareCalls.count == 2)
    }

    // MARK: Errors

    @Test func generateBeforePrepareIsNotReady() async {
        let client = Loopback(runtime: ScriptedRuntime()).client()
        await #expect(throws: FormatterRuntimeError.notReady) { try await client.generate(Self.request()) }
    }

    @Test(arguments: [
        FormatterRuntimeError.notReady, .modelLoading, .cancelled, .failed("could not load the model file"),
    ])
    func runtimeErrorsComeBackAsTheSameError(error: FormatterRuntimeError) async throws {
        let (_, client, service) = try await Self.ready()
        await service.setError(error)
        await #expect(throws: error) { try await client.generate(Self.request()) }
    }

    @Test func aPrepareErrorReachesTheCaller() async throws {
        let service = ScriptedRuntime()
        await service.setError(.failed("not a GGUF file"))
        let client = Loopback(runtime: service).client()
        await #expect(throws: FormatterRuntimeError.failed("not a GGUF file")) {
            try await client.prepare(Self.spec, prefix: Self.prefix)
        }
        // Nothing was marked ready.
        await #expect(throws: FormatterRuntimeError.notReady) { try await client.generate(Self.request()) }
    }

    // MARK: Cancel

    @Test func cancelReachesTheServiceWhileGenerateIsRunning() async throws {
        let (_, client, service) = try await Self.ready()
        await service.hold()
        let request = Self.request()
        let running = Task { try await client.generate(request) }
        // Wait until the service is inside generate.
        for _ in 0..<200 where await service.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        await client.cancel(request.id)
        let result = try await running.value
        #expect(result.stopReason == .interrupted)
        #expect(await service.cancelled == [request.id])
    }

    @Test func cancellingTheCallerTaskReleasesItAtOnceAndCancelsTheRequestInTheService() async throws {
        let (_, client, service) = try await Self.ready()
        await service.hold()
        let request = Self.request()
        let running = Task { try await client.generate(request) }
        for _ in 0..<200 where await service.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        running.cancel()
        await #expect(throws: FormatterRuntimeError.cancelled) { try await running.value }
        for _ in 0..<200 where await service.cancelled.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await service.cancelled == [request.id])
    }

    // MARK: Crash

    @Test func aServiceThatDiesMidTakeIsACrashNotAnAppCrash() async throws {
        let (loopback, client, service) = try await Self.ready()
        await service.hold()
        let running = Task { try await client.generate(Self.request()) }
        for _ in 0..<200 where await service.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        loopback.killService()
        await #expect(throws: FormatterRuntimeError.crashed) { try await running.value }
        await service.release()

        // The take falls back; the connection is gone, so the next take must prepare again, which starts
        // a fresh connection.
        await #expect(throws: FormatterRuntimeError.notReady) { try await client.generate(Self.request()) }
        await service.setError(nil)
        try await client.prepare(Self.spec, prefix: Self.prefix)
        let result = try await client.generate(Self.request())
        #expect(result.text == "ok")
        #expect(await service.prepareCalls.count == 2)
    }

    @Test func threeCrashesStopRestarts() async throws {
        var configuration = XPCFormatterRuntime.Configuration()
        configuration.crashLimit = 3
        let service = ScriptedRuntime()
        let loopback = Loopback(runtime: service)
        let client = loopback.client(configuration)
        for _ in 0..<3 {
            try await client.prepare(Self.spec, prefix: Self.prefix)
            await service.hold()
            let running = Task { try await client.generate(Self.request()) }
            for _ in 0..<200 where await service.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            loopback.killService()
            await #expect(throws: FormatterRuntimeError.crashed) { try await running.value }
            await service.release()
            await service.clearRequests()
        }
        await #expect(throws: FormatterRuntimeError.crashed) { try await client.prepare(Self.spec, prefix: Self.prefix) }
        // The breaker answers without opening a connection.
        #expect(await service.prepareCalls.count == 3)
    }

    // MARK: Load

    @Test func aSlowLoadFallsBackAtOnceAndKeepsLoadingInTheService() async throws {
        let service = ScriptedRuntime()
        await service.setPrepareDelay(.milliseconds(400))
        var configuration = XPCFormatterRuntime.Configuration()
        configuration.maxPrepareWait = .milliseconds(50)
        let client = Loopback(runtime: service).client(configuration)

        await #expect(throws: FormatterRuntimeError.modelLoading) { try await client.prepare(Self.spec, prefix: Self.prefix) }
        // The take that arrives while the load runs does not wait for it.
        await #expect(throws: FormatterRuntimeError.modelLoading) { try await client.generate(Self.request()) }

        // A prepare during the load joins it (and gives up again at the limit); once the load is done the next
        // prepare returns at once. The model is loaded once.
        await #expect(throws: FormatterRuntimeError.modelLoading) { try await client.prepare(Self.spec, prefix: Self.prefix) }
        try await Task.sleep(for: .milliseconds(450))
        try await client.prepare(Self.spec, prefix: Self.prefix)
        #expect(await service.prepareCalls.count == 1)
        let result = try await client.generate(Self.request())
        #expect(result.text == "ok")
    }

    // MARK: Idle and unload

    @Test func idleTimeoutUnloadsTheServiceAndTheNextTakePreparesAgain() async throws {
        var configuration = XPCFormatterRuntime.Configuration()
        configuration.idleTimeout = .milliseconds(150)
        let (_, client, service) = try await Self.ready(ScriptedRuntime(), configuration)
        _ = try await client.generate(Self.request())

        for _ in 0..<200 where await service.unloadCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await service.unloadCount >= 1)
        await #expect(throws: FormatterRuntimeError.notReady) { try await client.generate(Self.request()) }

        try await client.prepare(Self.spec, prefix: Self.prefix)
        #expect(try await client.generate(Self.request()).text == "ok")
        #expect(await service.prepareCalls.count == 2)
    }

    @Test func aRequestInFlightDelaysTheIdleUnload() async throws {
        var configuration = XPCFormatterRuntime.Configuration()
        configuration.idleTimeout = .milliseconds(100)
        let (_, client, service) = try await Self.ready(ScriptedRuntime(), configuration)
        await service.hold()
        let request = Self.request()
        let running = Task { try await client.generate(request) }
        for _ in 0..<200 where await service.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await service.unloadCount == 0)
        await client.cancel(request.id)
        _ = try await running.value
    }

    @Test func unloadFreesTheModelAndClosingTheLastConnectionEndsTheService() async throws {
        let (loopback, client, service) = try await Self.ready()
        await client.unload()
        #expect(await service.unloadCount >= 1)
        for _ in 0..<200 where loopback.lastConnectionClosedCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(loopback.lastConnectionClosedCount == 1)
        await #expect(throws: FormatterRuntimeError.notReady) { try await client.generate(Self.request()) }
    }

    // MARK: Wire

    @Test func theSpecSurvivesTheWireFormat() throws {
        var spec = Self.spec
        spec.endpoint = URL(string: "http://localhost:11434")
        let data = try JSONEncoder().encode(XPCPrepareRequest(spec: spec, prefix: Self.prefix))
        let decoded = try JSONDecoder().decode(XPCPrepareRequest.self, from: data)
        #expect(decoded.spec == spec)
        #expect(decoded.promptPrefix == Self.prefix)
    }

    @Test func garbageIsAnInvalidRequestNotACrash() async throws {
        let service = FormatterXPCService(runtime: ScriptedRuntime())
        let error = await withCheckedContinuation { continuation in
            service.prepare(Data("not json".utf8) as NSData) { continuation.resume(returning: $0) }
        }
        #expect(error?.domain == formatterXPCErrorDomain)
        #expect(error?.code == FormatterXPCErrorCode.invalidRequest.rawValue)
    }
}

// MARK: - Review fixes

/// A service that takes every request and never answers a generate, and never dies.
final class StalledService: NSObject, FormatterXPCProtocol, @unchecked Sendable {
    func prepare(_ request: NSData, withReply reply: @escaping (NSError?) -> Void) { reply(nil) }
    func generate(_ request: NSData, withReply reply: @escaping (NSData?, NSError?) -> Void) {}
    func cancel(_ requestID: String) {}
    func shutdown(withReply reply: @escaping () -> Void) { reply() }
}

final class StalledListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
    private let service = StalledService()
    private nonisolated(unsafe) static var alive: [StalledListener] = []

    override init() {
        super.init()
        listener.delegate = self
        listener.resume()
        Self.alive.append(self)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: FormatterXPCProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

@Suite("XPCFormatterRuntime, review fixes")
struct XPCFormatterRuntimeReviewTests {
    static let prefixA = PromptPrefix(messages: [ChatMessage(role: .system, content: "rules A")])
    static let prefixB = PromptPrefix(messages: [ChatMessage(role: .system, content: "rules B")])
    static let spec = XPCFormatterRuntimeTests.spec

    static func request(prefix: PromptPrefix?, deadline: Duration = .seconds(5)) -> GenerationRequest {
        GenerationRequest(
            suffix: [ChatMessage(role: .user, content: "hello there")], maxTokens: 16, deadline: .now + deadline,
            prefixKey: prefix?.key)
    }

    // 4: the prefix a request was built for

    @Test func aRequestRunsUnderItsOwnPrefixWhenAnotherWasPreparedInBetween() async throws {
        let service = ScriptedRuntime()
        let client = Loopback(runtime: service).client()
        try await client.prepare(Self.spec, prefix: Self.prefixA)
        try await client.prepare(Self.spec, prefix: Self.prefixB)

        let underA = Self.request(prefix: Self.prefixA)
        let underB = Self.request(prefix: Self.prefixB)
        _ = try await client.generate(underA)
        _ = try await client.generate(underB)
        let seen = await service.generatedUnder
        #expect(seen[underA.id] == Self.prefixA.key)
        #expect(seen[underB.id] == Self.prefixB.key)
    }

    @Test func manyInterleavedRequestsEachSeeTheirOwnPrefix() async throws {
        let service = ScriptedRuntime()
        await service.setGenerateDelay(.milliseconds(3))
        let client = Loopback(runtime: service).client()
        try await client.prepare(Self.spec, prefix: Self.prefixA)
        try await client.prepare(Self.spec, prefix: Self.prefixB)

        var requests: [(GenerationRequest, PromptPrefix)] = []
        for index in 0..<24 {
            let prefix = index.isMultiple(of: 2) ? Self.prefixA : Self.prefixB
            requests.append((Self.request(prefix: prefix), prefix))
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (request, _) in requests {
                group.addTask { _ = try await client.generate(request) }
            }
            try await group.waitForAll()
        }
        let seen = await service.generatedUnder
        for (request, prefix) in requests { #expect(seen[request.id] == prefix.key) }
    }

    @Test func aPrefixTheServiceNeverSawIsNotReadyNotSomeoneElsesPrompt() async throws {
        let service = ScriptedRuntime()
        let client = Loopback(runtime: service).client()
        try await client.prepare(Self.spec, prefix: Self.prefixA)
        let stranger = PromptPrefix(messages: [ChatMessage(role: .system, content: "never prepared")])
        await #expect(throws: FormatterRuntimeError.notReady) { try await client.generate(Self.request(prefix: stranger)) }
        #expect(await service.requests.isEmpty)
    }

    // 2: idle timer

    @Test func aPrepareThatFindsTheModelReadyRestartsTheIdleTimer() async throws {
        var configuration = XPCFormatterRuntime.Configuration()
        configuration.idleTimeout = .milliseconds(200)
        let service = ScriptedRuntime()
        let client = Loopback(runtime: service).client(configuration)
        try await client.prepare(Self.spec, prefix: Self.prefixA)
        _ = try await client.generate(Self.request(prefix: Self.prefixA))
        try await Task.sleep(for: .milliseconds(100))
        // A short take that skips generate: prepare cancels the timer, and must set it again.
        try await client.prepare(Self.spec, prefix: Self.prefixA)
        for _ in 0..<200 where await service.unloadCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await service.unloadCount >= 1)
    }

    // 8: crashes per model

    @Test func crashesCountPerModelAndAnotherModelStartsClean() async throws {
        var configuration = XPCFormatterRuntime.Configuration()
        configuration.crashLimit = 2
        let service = ScriptedRuntime()
        let loopback = Loopback(runtime: service)
        let client = loopback.client(configuration)
        for _ in 0..<2 {
            try await client.prepare(Self.spec, prefix: Self.prefixA)
            await service.hold()
            let running = Task { try await client.generate(Self.request(prefix: Self.prefixA)) }
            for _ in 0..<200 where await service.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            loopback.killService()
            await #expect(throws: FormatterRuntimeError.crashed) { try await running.value }
            await service.release()
            await service.clearRequests()
        }
        await #expect(throws: FormatterRuntimeError.crashed) { try await client.prepare(Self.spec, prefix: Self.prefixA) }

        var other = Self.spec
        other.modelURL = URL(fileURLWithPath: "/models/another-model.gguf")
        other.identifier = "another-model"
        try await client.prepare(other, prefix: Self.prefixA)
        #expect(try await client.generate(Self.request(prefix: Self.prefixA)).text == "ok")
    }

    // 9: a load that was unloaded while it ran

    @Test func unloadingMidLoadThenPreparingTheSameModelPublishesTheNewLoad() async throws {
        let service = ScriptedRuntime()
        await service.setPrepareDelay(.milliseconds(300))
        let client = Loopback(runtime: service).client()
        let first = Task { try? await client.prepare(Self.spec, prefix: Self.prefixA) }
        try await Task.sleep(for: .milliseconds(60))
        await client.unload()
        await service.setPrepareDelay(.zero)
        try await client.prepare(Self.spec, prefix: Self.prefixA)
        #expect(try await client.generate(Self.request(prefix: Self.prefixA)).text == "ok")
        _ = await first.value
        // The new load stays published after the old one finishes.
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await client.generate(Self.request(prefix: Self.prefixA)).text == "ok")
    }

    // 10: the old service still exiting

    @Test func aPrepareRightAfterAnUnloadReconnectsAndIsNotACrash() async throws {
        var configuration = XPCFormatterRuntime.Configuration()
        configuration.crashLimit = 1
        let service = ScriptedRuntime()
        let loopback = Loopback(runtime: service)
        let client = loopback.client(configuration)
        try await client.prepare(Self.spec, prefix: Self.prefixA)
        await client.unload()

        loopback.rejectNextConnections(1)
        try await client.prepare(Self.spec, prefix: Self.prefixA)
        #expect(try await client.generate(Self.request(prefix: Self.prefixA)).text == "ok")
        // With a limit of one, a counted crash would block this.
        await client.unload()
        try await client.prepare(Self.spec, prefix: Self.prefixA)
    }

    // 12: a service that stalls

    @Test func aCancelledGenerateReturnsAtOnceEvenWhenTheServiceNeverAnswers() async throws {
        let stalled = StalledListener()
        let client = XPCFormatterRuntime(endpoint: .listener(stalled.listener.endpoint))
        try await client.prepare(Self.spec, prefix: Self.prefixA)
        let running = Task { try await client.generate(Self.request(prefix: Self.prefixA, deadline: .seconds(60))) }
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        running.cancel()
        await #expect(throws: FormatterRuntimeError.cancelled) { try await running.value }
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func thePipelineTimeoutReturnsTheFallbackWhileTheServiceStalls() async throws {
        let stalled = StalledListener()
        let client = XPCFormatterRuntime(endpoint: .listener(stalled.listener.endpoint))
        var configuration = FormatterPipeline.Configuration()
        configuration.timeBudget = { _ in .milliseconds(300) }
        let pipeline = try FormatterPipeline.bundled(runtime: client, configuration: configuration)
        try await client.prepare(Self.spec, prefix: pipeline.prefix)

        let started = ContinuousClock.now
        let outcome = await pipeline.format("um so i think we should meet on tuesday at three", context: .plain)
        #expect(outcome.reason == .timeout)
        #expect(outcome.text.lowercased().contains("tuesday"))
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    // 5: prepare under the caller's deadline

    @Test func prepareWaitsNoLongerThanTheCallersDeadline() async throws {
        let service = ScriptedRuntime()
        await service.setPrepareDelay(.milliseconds(600))
        let client = Loopback(runtime: service).client()
        let started = ContinuousClock.now
        await #expect(throws: FormatterRuntimeError.modelLoading) {
            try await client.prepare(Self.spec, prefix: Self.prefixA, deadline: .now + .milliseconds(80))
        }
        #expect(ContinuousClock.now - started < .milliseconds(400))
    }
}
