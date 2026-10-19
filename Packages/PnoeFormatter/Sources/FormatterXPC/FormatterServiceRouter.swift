import FormatterCore
import Foundation

/// Runs one prepare or generate at a time, in the order they arrive. A runtime holds one model and one cached
/// prefix; two workflows sharing it must not have one's `prepare` land in the middle of the other's request.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await work()
    }

    private func acquire() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if busy {
                waiters.append(continuation)
                lock.unlock()
            } else {
                busy = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    private func release() {
        lock.lock()
        if waiters.isEmpty {
            busy = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}

/// What sits between the connections and the runtime in the service: it serializes prepare and generate, and
/// keeps the prefixes it was prepared with. A request that names a prefix other than the current one gets that
/// prefix prepared first (the model stays loaded; only the cached prefix is replaced), or `.notReady` when the
/// service never saw it, so a take never runs under another workflow's prompt.
final class FormatterServiceRouter: @unchecked Sendable {
    private let runtime: any FormatterRuntime
    private let gate = AsyncGate()
    private let lock = NSLock()
    private var spec: RuntimeModelSpec?
    private var currentKey: String?
    private var known: [String: PromptPrefix] = [:]
    private var knownOrder: [String] = []
    private var cancelledEarly: Set<UUID> = []
    private static let rememberedPrefixes = 8

    init(runtime: any FormatterRuntime) {
        self.runtime = runtime
    }

    func prepare(_ spec: RuntimeModelSpec, prefix: PromptPrefix) async throws {
        try await gate.run { [self] in
            try await runtime.prepare(spec, prefix: prefix)
            remember(spec: spec, prefix: prefix)
        }
    }

    func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        try await gate.run { [self] in
            defer { forget(request.id) }
            if wasCancelledEarly(request.id) { return GenerationResult(text: "", stopReason: .interrupted) }
            if let key = request.prefixKey, let switchTo = prefixToSwitch(to: key) {
                guard let (spec, prefix) = switchTo else { throw FormatterRuntimeError.notReady }
                try await runtime.prepare(spec, prefix: prefix)
                setCurrent(key)
            }
            return try await runtime.generate(request)
        }
    }

    func cancel(_ id: UUID) async {
        markCancelled(id)
        await runtime.cancel(id)
    }

    func unload() async {
        clearCurrent()
        await runtime.unload()
    }

    // MARK: State (short critical sections, never held across an await)

    private func markCancelled(_ id: UUID) {
        lock.lock()
        if cancelledEarly.count > 64 { cancelledEarly.removeAll() }
        cancelledEarly.insert(id)
        lock.unlock()
    }

    private func clearCurrent() {
        lock.lock()
        spec = nil
        currentKey = nil
        lock.unlock()
    }

    private func remember(spec: RuntimeModelSpec, prefix: PromptPrefix) {
        lock.lock()
        defer { lock.unlock() }
        self.spec = spec
        let key = prefix.key
        currentKey = key
        known[key] = prefix
        knownOrder.removeAll { $0 == key }
        knownOrder.append(key)
        while knownOrder.count > Self.rememberedPrefixes {
            known[knownOrder.removeFirst()] = nil
        }
    }

    /// nil: the request's prefix is already current. A value (itself nil when unknown): what to prepare.
    private func prefixToSwitch(to key: String) -> (RuntimeModelSpec, PromptPrefix)?? {
        lock.lock()
        defer { lock.unlock() }
        if currentKey == key { return nil }
        guard let spec, let prefix = known[key] else { return .some(nil) }
        return .some((spec, prefix))
    }

    private func setCurrent(_ key: String) {
        lock.lock()
        currentKey = key
        lock.unlock()
    }

    private func wasCancelledEarly(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledEarly.contains(id)
    }

    private func forget(_ id: UUID) {
        lock.lock()
        cancelledEarly.remove(id)
        lock.unlock()
    }
}
