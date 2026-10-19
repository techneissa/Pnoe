import FormatterCore
import FormatterXPC
import Foundation

/// A service hosted in this process on an anonymous listener: the real `NSXPCConnection` code path (JSON
/// payloads, reply blocks, interruption) with a scripted runtime behind it and no model.
final class Loopback: @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
    private let delegate: FormatterXPCListenerDelegate
    private let lock = NSLock()
    private var connections: [NSXPCConnection] = []
    private let lastClosed = Counter()
    private let rejecting = Counter()

    var lastConnectionClosedCount: Int { lastClosed.value }

    init(runtime: any FormatterRuntime) {
        let closed = lastClosed
        delegate = FormatterXPCListenerDelegate(runtime: runtime, onLastConnectionClosed: { closed.increment() })
        let rejecting = self.rejecting
        let tracking = TrackingDelegate(wrapping: delegate, shouldReject: { rejecting.decrementIfPositive() }) { [weak self] connection in
            self?.lock.lock()
            self?.connections.append(connection)
            self?.lock.unlock()
        }
        trackingDelegate = tracking
        listener.delegate = tracking
        listener.resume()
        Self.aliveLock.lock()
        Self.alive.append(self)
        Self.aliveLock.unlock()
    }

    private var trackingDelegate: TrackingDelegate?

    /// A listener that is deallocated takes its connections with it, which a test would read as a crash. The
    /// test process is short, so loopbacks live until it ends.
    private nonisolated(unsafe) static var alive: [Loopback] = []
    private static let aliveLock = NSLock()

    func client(
        _ configuration: XPCFormatterRuntime.Configuration = .init(), id: FormatterRuntimeID = .llama
    ) -> XPCFormatterRuntime {
        XPCFormatterRuntime(endpoint: .listener(listener.endpoint), id: id, configuration: configuration)
    }

    /// The next `count` connections are refused, like a client that reaches a service still exiting.
    func rejectNextConnections(_ count: Int) { for _ in 0..<count { rejecting.increment() } }

    /// Ends every server-side connection the way a dying service does: the client sees an interruption.
    func killService() {
        lock.lock()
        let open = connections
        connections = []
        lock.unlock()
        for connection in open { connection.invalidate() }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
    func decrementIfPositive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return false }
        count -= 1
        return true
    }
}

private final class TrackingDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let inner: FormatterXPCListenerDelegate
    private let onConnection: @Sendable (NSXPCConnection) -> Void
    private let shouldReject: @Sendable () -> Bool

    init(
        wrapping inner: FormatterXPCListenerDelegate, shouldReject: @escaping @Sendable () -> Bool,
        onConnection: @escaping @Sendable (NSXPCConnection) -> Void
    ) {
        self.inner = inner
        self.shouldReject = shouldReject
        self.onConnection = onConnection
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        if shouldReject() { return false }
        onConnection(newConnection)
        return inner.listener(listener, shouldAcceptNewConnection: newConnection)
    }
}

/// A runtime the test steers: `generate` waits until the test lets it go, `prepare` can take a while.
actor ScriptedRuntime: FormatterRuntime {
    nonisolated let id: FormatterRuntimeID = .llama
    var prepareDelay: Duration = .zero
    var prepareCalls: [(RuntimeModelSpec, PromptPrefix)] = []
    var requests: [GenerationRequest] = []
    var cancelled: [UUID] = []
    var unloadCount = 0
    var currentPrefix: PromptPrefix?
    /// For each request: the key of the prefix that was current when it ran.
    var generatedUnder: [UUID: String] = [:]
    var generateDelay: Duration = .zero
    var unloadDelay: Duration = .zero
    private var gate: CheckedContinuation<Void, Never>?
    private var holdGenerate = false
    private var started: CheckedContinuation<Void, Never>?
    private var startedAlready = false
    private var onGenerateStart: (@Sendable () -> Void)?
    var reply = GenerationResult(text: "ok", stopReason: .eos, promptTokens: 12, generatedTokens: 3)
    var error: FormatterRuntimeError?

    func release() { gate?.resume(); gate = nil }
    func clearRequests() { requests = []; cancelled = [] }
    func setUnloadDelay(_ delay: Duration) { unloadDelay = delay }
    func setGenerateDelay(_ delay: Duration) { generateDelay = delay }
    func setPrepareDelay(_ delay: Duration) { prepareDelay = delay }
    func setReply(_ result: GenerationResult) { reply = result }
    func setError(_ error: FormatterRuntimeError?) { self.error = error }
    func hold() { holdGenerate = true }
    func onStart(_ action: @escaping @Sendable () -> Void) { onGenerateStart = action }

    func prepare(_ spec: RuntimeModelSpec, prefix: PromptPrefix) async throws {
        prepareCalls.append((spec, prefix))
        if prepareDelay > .zero { try await Task.sleep(for: prepareDelay) }
        if let error { throw error }
        currentPrefix = prefix
    }

    func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        requests.append(request)
        generatedUnder[request.id] = currentPrefix?.key
        if generateDelay > .zero { try await Task.sleep(for: generateDelay) }
        onGenerateStart?()
        if let error { throw error }
        if holdGenerate {
            await withCheckedContinuation { gate = $0 }
            holdGenerate = false
            if cancelled.contains(request.id) { return GenerationResult(text: "", stopReason: .interrupted) }
        }
        return reply
    }

    func cancel(_ requestID: UUID) async {
        cancelled.append(requestID)
        gate?.resume()
        gate = nil
    }

    func unload() async {
        unloadCount += 1
        if unloadDelay > .zero { try? await Task.sleep(for: unloadDelay) }
    }
}
