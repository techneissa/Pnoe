import Foundation

/// One runtime in front of several: a model spec goes to the runtime that can load it (`spec.backend`, nil
/// for the default), and a request goes to the runtime its prefix was prepared on. The Built-in engine uses it
/// to put the llama.cpp service and the MLX service behind the single `FormatterRuntime` every workflow shares.
///
/// Each backend keeps its own state (loaded model, idle timer, crash count), so a model on one never reloads
/// because a workflow switched to a model on the other. `unload` and `cancel` reach both.
public final class RoutingFormatterRuntime: FormatterRuntime, @unchecked Sendable {
    public let id: FormatterRuntimeID
    private let backends: [FormatterRuntimeID: any FormatterRuntime]
    private let fallback: FormatterRuntimeID
    private let lock = NSLock()
    private var last: FormatterRuntimeID
    private var routes: [String: FormatterRuntimeID] = [:]
    private var routeOrder: [String] = []
    private static let rememberedRoutes = 16

    /// `backends` maps each engine to its runtime; a spec without a backend (or with one that is not listed)
    /// goes to `fallback`.
    public init(backends: [FormatterRuntimeID: any FormatterRuntime], fallback: FormatterRuntimeID) {
        precondition(backends[fallback] != nil, "the fallback backend must be listed")
        self.backends = backends
        self.fallback = fallback
        self.last = fallback
        id = fallback
    }

    /// The runtime that loads `spec`.
    public func backend(for spec: RuntimeModelSpec) -> FormatterRuntimeID {
        if let wanted = spec.backend, backends[wanted] != nil { return wanted }
        return fallback
    }

    public func prepare(_ spec: RuntimeModelSpec, prefix: PromptPrefix) async throws {
        let target = route(spec, prefix: prefix)
        try await runtime(target).prepare(spec, prefix: prefix)
    }

    public func prepare(_ spec: RuntimeModelSpec, prefix: PromptPrefix, deadline: ContinuousClock.Instant) async throws {
        let target = route(spec, prefix: prefix)
        try await runtime(target).prepare(spec, prefix: prefix, deadline: deadline)
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        try await runtime(target(for: request)).generate(request)
    }

    public func cancel(_ requestID: UUID) async {
        for runtime in backends.values { await runtime.cancel(requestID) }
    }

    /// Frees every backend's model. The services end with their models.
    public func unload() async {
        await withTaskGroup(of: Void.self) { group in
            for runtime in backends.values { group.addTask { await runtime.unload() } }
        }
    }

    // MARK: Routes (short critical sections, never held across an await)

    private func runtime(_ id: FormatterRuntimeID) -> any FormatterRuntime { backends[id] ?? backends[fallback]! }

    /// Remembers where `prefix` was prepared, so the request built for it finds the same backend even when a
    /// workflow on the other backend prepared in between.
    private func route(_ spec: RuntimeModelSpec, prefix: PromptPrefix) -> FormatterRuntimeID {
        let target = backend(for: spec)
        lock.lock()
        defer { lock.unlock() }
        last = target
        let key = prefix.key
        routes[key] = target
        routeOrder.removeAll { $0 == key }
        routeOrder.append(key)
        while routeOrder.count > Self.rememberedRoutes { routes[routeOrder.removeFirst()] = nil }
        return target
    }

    private func target(for request: GenerationRequest) -> FormatterRuntimeID {
        lock.lock()
        defer { lock.unlock() }
        if let key = request.prefixKey, let known = routes[key] { return known }
        return last
    }
}
