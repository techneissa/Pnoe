import FormatterCore
import Foundation
import os

/// `FormatterRuntime` over `NSXPCConnection`: the model lives in the embedded XPC service, so a crash or a
/// memory spike there never reaches the app. Every failure is a `FormatterRuntimeError`, which the pipeline
/// turns into the plain transcript.
///
/// - Load: `prepare` sends the model and the fixed prompt prefix once and waits at most the caller's deadline
///   (and `Configuration.maxPrepareWait`); a load that is still running then keeps going in the service and the
///   take falls back (`modelLoading`). The next `prepare` joins it.
/// - Prefix: a request names the prefix it was built for; the service switches to it if another workflow
///   prepared a different one in between.
/// - Idle: after `idleTimeout` without a request the service is told to unload and exit, which frees all
///   Metal buffers. Memory pressure and a toggle-off call `unload()` the same way.
/// - Crash: an interrupted connection is `.crashed` for the call in flight. The next `prepare` starts the
///   service again; three crashes of the same model inside `crashWindow` stop restarts of that model until the
///   app restarts. Another model starts clean, and an interruption right after an unload (the old service
///   still exiting) is not a crash: the call reconnects once.
/// - Stall: a `generate` whose task is cancelled returns at once, even when the service never answers.
public actor XPCFormatterRuntime: FormatterRuntime {
    /// Where the connection goes: the embedded service, or a listener endpoint for tests.
    public struct Endpoint: @unchecked Sendable {
        let makeConnection: @Sendable () -> NSXPCConnection

        public static func service(named name: String = formatterXPCServiceName) -> Endpoint {
            Endpoint { NSXPCConnection(serviceName: name) }
        }

        public static func listener(_ endpoint: NSXPCListenerEndpoint) -> Endpoint {
            Endpoint { NSXPCConnection(listenerEndpoint: endpoint) }
        }
    }

    public struct Configuration: Sendable {
        public var idleTimeout: Duration = .seconds(600)
        public var maxPrepareWait: Duration = .seconds(20)
        public var crashLimit = 3
        public var crashWindow: Duration = .seconds(600)
        /// How long `unload` waits for the service to acknowledge before it drops the connection.
        public var shutdownWait: Duration = .seconds(3)
        /// An interruption this soon after an unload is the old service still exiting, not a crash.
        public var shutdownGrace: Duration = .seconds(1)

        public init() {}
    }

    public nonisolated let id: FormatterRuntimeID = .llama

    private let endpoint: Endpoint
    private let configuration: Configuration
    private let logger = Logger(subsystem: "com.techneissa.pnoe", category: "XPCFormatterRuntime")

    private var connection: NSXPCConnection?
    private var connectionToken = UUID()
    private var connectionModel = ""
    private var prepared: PrepareKey?
    private var loading: (id: UUID, key: PrepareKey, task: Task<Void, Error>)?
    private var requestsInFlight = 0
    private var idleToken: UUID?
    private var crashes: [String: [ContinuousClock.Instant]] = [:]
    private var lastShutdown: ContinuousClock.Instant?

    private struct PrepareKey: Equatable {
        var spec: RuntimeModelSpec
        var prefix: PromptPrefix
        var model: String { spec.modelURL?.path ?? spec.identifier }
    }

    public init(endpoint: Endpoint = .service(), configuration: Configuration = Configuration()) {
        self.endpoint = endpoint
        self.configuration = configuration
    }

    // MARK: FormatterRuntime

    public func prepare(_ spec: RuntimeModelSpec, prefix: PromptPrefix) async throws {
        try await prepare(spec, prefix: prefix, deadline: .now + configuration.maxPrepareWait)
    }

    public func prepare(_ spec: RuntimeModelSpec, prefix: PromptPrefix, deadline: ContinuousClock.Instant) async throws {
        let key = PrepareKey(spec: spec, prefix: prefix)
        if restartsAreBlocked(for: key.model) { throw FormatterRuntimeError.crashed }
        cancelIdleTimer()
        if prepared == key, connection != nil {
            // Nothing will call `generate` for this take if it is skipped, so the idle timer starts again.
            if requestsInFlight == 0, loading == nil { scheduleIdleTimer() }
            return
        }

        let task: Task<Void, Error>
        if let loading, loading.key == key {
            task = loading.task
        } else {
            // Unstructured on purpose: a caller that stops waiting must not stop the load.
            let id = UUID()
            task = Task { try await self.load(key, id: id) }
            loading = (id, key, task)
        }

        let limit = min(configuration.maxPrepareWait, max(.zero, deadline - .now))
        try await Self.wait(for: task, atMost: limit)
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        if loading != nil { throw FormatterRuntimeError.modelLoading }
        guard prepared != nil, let connection else { throw FormatterRuntimeError.notReady }
        cancelIdleTimer()
        requestsInFlight += 1
        defer {
            requestsInFlight -= 1
            if requestsInFlight == 0 { scheduleIdleTimer() }
        }

        let wire = XPCGenerateRequest(
            id: request.id,
            suffix: request.suffix,
            maxTokens: request.maxTokens,
            secondsLeft: Self.seconds(request.deadline - .now),
            temperature: request.temperature,
            prefixKey: request.prefixKey
        )
        let payload = try JSONEncoder().encode(wire)
        let token = connectionToken
        let id = request.id
        do {
            let data = try await withTaskCancellationHandler {
                try await Self.call(SendableConnection(connection)) { proxy, reply in
                    proxy.generate(payload as NSData) { data, error in
                        if let error { reply.resolve(.failure(error)) } else if let data {
                            reply.resolve(.success(data as Data))
                        } else {
                            reply.resolve(.failure(makeFormatterXPCError(.failed("empty reply"))))
                        }
                    }
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
            let response = try JSONDecoder().decode(XPCGenerateResponse.self, from: data)
            return GenerationResult(
                text: response.text, stopReason: response.stopReason,
                promptTokens: response.promptTokens, generatedTokens: response.generatedTokens)
        } catch {
            if error is CancellationError { throw FormatterRuntimeError.cancelled }
            let mapped = (error as? FormatterRuntimeError) ?? runtimeError(fromXPC: error)
            if mapped == .crashed { connectionDied(token: token) }
            throw mapped
        }
    }

    public func cancel(_ requestID: UUID) async {
        guard let connection else { return }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as? FormatterXPCProtocol
        proxy?.cancel(requestID.uuidString)
    }

    /// Unloads the model and ends the service process. The next `prepare` starts it again.
    public func unload() async {
        cancelIdleTimer()
        loading?.task.cancel()
        loading = nil
        prepared = nil
        guard let connection else { return }
        self.connection = nil
        connectionToken = UUID()
        let wait = configuration.shutdownWait
        let box = SendableConnection(connection)
        _ = try? await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await Self.call(box) { proxy, reply in
                    proxy.shutdown { reply.resolve(.success(Data())) }
                }
            }
            group.addTask { try await Task.sleep(for: wait) }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
        connection.invalidate()
        lastShutdown = .now
    }

    // MARK: Loading

    private func load(_ key: PrepareKey, id: UUID) async throws {
        var attempts = 0
        while true {
            attempts += 1
            let connection = ensureConnection(model: key.model)
            let token = connectionToken
            do {
                let payload = try JSONEncoder().encode(XPCPrepareRequest(spec: key.spec, prefix: key.prefix))
                _ = try await Self.call(SendableConnection(connection)) { proxy, reply in
                    proxy.prepare(payload as NSData) { error in
                        if let error { reply.resolve(.failure(error)) } else { reply.resolve(.success(Data())) }
                    }
                }
                break
            } catch {
                let mapped = (error as? FormatterRuntimeError) ?? runtimeError(fromXPC: error)
                if mapped == .crashed {
                    // The service we reached may be the one still exiting after an unload: connect again, once.
                    let retry = shutDownRecently && attempts < 2 && loading?.id == id
                    connectionDied(token: token)
                    if retry { continue }
                }
                if loading?.id == id { loading = nil }
                throw mapped
            }
        }
        // A load that was unloaded or replaced while it ran is not published.
        if loading?.id == id {
            prepared = key
            loading = nil
            scheduleIdleTimer()
        }
    }

    // MARK: Connection

    private func ensureConnection(model: String) -> NSXPCConnection {
        if let connection { return connection }
        let created = endpoint.makeConnection()
        created.remoteObjectInterface = NSXPCInterface(with: FormatterXPCProtocol.self)
        let token = UUID()
        created.interruptionHandler = { [weak self] in
            Task { await self?.connectionDied(token: token) }
        }
        created.invalidationHandler = { [weak self] in
            Task { await self?.connectionDied(token: token) }
        }
        created.resume()
        connection = created
        connectionToken = token
        connectionModel = model
        return created
    }

    /// The service went away without being asked to. Counts one crash for the model it was running, unless it
    /// was still exiting after an unload.
    private func connectionDied(token: UUID) {
        guard connectionToken == token, let dead = connection else { return }
        connection = nil
        connectionToken = UUID()
        prepared = nil
        // A load that was running on this connection ends with the failed call and clears itself.
        dead.invalidate()
        cancelIdleTimer()
        guard !shutDownRecently else { return }
        let now = ContinuousClock.now
        let model = connectionModel
        let recent = (crashes[model] ?? []).filter { now - $0 < configuration.crashWindow } + [now]
        crashes[model] = recent
        logger.error("Formatter service ended unexpectedly (\(recent.count, privacy: .public) in the window)")
    }

    private var shutDownRecently: Bool {
        guard let lastShutdown else { return false }
        return ContinuousClock.now - lastShutdown < configuration.shutdownGrace
    }

    private func restartsAreBlocked(for model: String) -> Bool {
        let now = ContinuousClock.now
        return (crashes[model] ?? []).filter { now - $0 < configuration.crashWindow }.count >= configuration.crashLimit
    }

    // MARK: Idle

    private func scheduleIdleTimer() {
        let token = UUID()
        idleToken = token
        let timeout = configuration.idleTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.idleTimerFired(token)
        }
    }

    private func cancelIdleTimer() {
        idleToken = nil
    }

    private func idleTimerFired(_ token: UUID) async {
        guard idleToken == token, requestsInFlight == 0, loading == nil else { return }
        logger.info("Formatter service idle, unloading")
        await unload()
    }

    // MARK: Helpers

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// Waits for `task` but not longer than `limit`, and does not wait for it to finish once the limit passed
    /// (a task group would). The load keeps running either way.
    private static func wait(for task: Task<Void, Error>, atMost limit: Duration) async throws {
        let race = Race()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                race.install(continuation)
                Task {
                    race.finish(await task.result)
                }
                race.setTimer(Task {
                    try? await Task.sleep(for: limit)
                    race.finish(.failure(FormatterRuntimeError.modelLoading))
                })
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    /// One proxy call as an `async` function. The error handler and the reply can both fire (a service that
    /// dies after replying), so the continuation is resumed once. A cancelled caller is released at once, so a
    /// service that stalls without dying cannot hold a take past its deadline.
    private static func call(
        _ box: SendableConnection,
        _ body: @Sendable (FormatterXPCProtocol, OnceReply) -> Void
    ) async throws -> Data {
        let reply = OnceReply()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                reply.install(continuation)
                guard
                    let proxy = box.value.remoteObjectProxyWithErrorHandler({ error in
                        reply.resolve(.failure(error))
                    }) as? FormatterXPCProtocol
                else {
                    reply.resolve(.failure(makeFormatterXPCError(.failed("no proxy"))))
                    return
                }
                body(proxy, reply)
            }
        } onCancel: {
            reply.resolve(.failure(CancellationError()))
        }
    }
}

/// `NSXPCConnection` is thread-safe but not marked `Sendable`.
struct SendableConnection: @unchecked Sendable {
    let value: NSXPCConnection
    init(_ value: NSXPCConnection) { self.value = value }
}

/// Resumes one continuation with whichever of the load, the time limit and a cancel comes first.
private final class Race: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var timer: Task<Void, Never>?
    private var early: Result<Void, Error>?

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let early {
            lock.unlock()
            continuation.resume(with: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func setTimer(_ timer: Task<Void, Never>) {
        lock.lock()
        let finished = continuation == nil && early != nil
        if !finished { self.timer = timer }
        lock.unlock()
        if finished { timer.cancel() }
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard early == nil else {
            lock.unlock()
            return
        }
        early = result
        let continuation = self.continuation
        self.continuation = nil
        let timer = self.timer
        lock.unlock()
        timer?.cancel()
        continuation?.resume(with: result)
    }
}

/// The single answer to one proxy call: a reply, an error, or a cancel, whichever is first. A cancel that
/// comes before the continuation is installed is kept and delivered when it is.
final class OnceReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var early: Result<Data, Error>?

    func install(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        if let early {
            lock.unlock()
            continuation.resume(with: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resolve(_ result: Result<Data, Error>) {
        lock.lock()
        guard early == nil else {
            lock.unlock()
            return
        }
        early = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
