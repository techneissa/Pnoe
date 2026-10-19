import FormatterCore
import Foundation
import Synchronization
import llama

/// `FormatterRuntime` over the llama.cpp C API. It runs inside the XPC service, never in the app.
///
/// - Settings: Metal with every layer offloaded, flash attention, mmap, a 4096-token context and a 512-token
///   batch. Greedy sampling, no grammar. Generation ends at an end-of-generation token or the token cap.
/// - Prefix cache: `prepare` decodes the fixed prompt prefix (system turn and shot turns) once. A request
///   cuts the cache back to the prefix and decodes only its own turn. Gemma 4's sliding-window layers can
///   refuse a partial cut (`llama_memory_seq_rm` returns false); the context is created with a full-size
///   sliding window cache so the cut works, and if it still refuses, the prefix state saved at `prepare` is
///   restored instead.
/// - Threads: llama.cpp contexts are not thread-safe, so every call runs on one serial queue. `cancel` only
///   sets a flag that the decode loop reads between tokens.
public final class LlamaRuntime: FormatterRuntime, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var gpuLayers: Int32 = 99
        public var batchSize: UInt32 = 512
        public var threads: Int32 = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        public init() {}
    }

    public let id: FormatterRuntimeID = .llama

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "com.techneissa.pnoe.llama-runtime", qos: .userInitiated)
    /// Request ids cancelled before or while they run, and the unload epoch.
    private let flags = RuntimeFlags()
    /// Only touched on `queue`.
    private nonisolated(unsafe) var engine: Engine?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        LlamaBackend.start()
    }

    // MARK: FormatterRuntime

    public func prepare(_ spec: RuntimeModelSpec, prefix: PromptPrefix) async throws {
        guard let modelURL = spec.modelURL else { throw FormatterRuntimeError.failed("the model has no file") }
        let configuration = self.configuration
        try await onQueue { [self] in
            if let loaded = engine, loaded.matches(modelURL: modelURL, contextLength: spec.contextLength) {
                if loaded.hasPrefix(prefix) { return }
                do {
                    try loaded.setPrefix(prefix)
                } catch {
                    engine = nil
                    throw error
                }
                return
            }
            engine = nil
            let loaded = try Engine(modelURL: modelURL, contextLength: spec.contextLength, configuration: configuration)
            try loaded.setPrefix(prefix)
            engine = loaded
        }
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        let epoch = flags.epoch
        return try await onQueue { [self] in
            defer { flags.forget(request.id) }
            guard let engine else { throw FormatterRuntimeError.notReady }
            let stop = StopCheck(flags: flags, id: request.id, epoch: epoch, deadline: request.deadline)
            return try engine.generate(request, stop: stop)
        }
    }

    public func cancel(_ requestID: UUID) async {
        flags.cancel(requestID)
    }

    /// Stops a running decode, then frees the model, its context and all Metal buffers.
    public func unload() async {
        flags.bumpEpoch()
        try? await onQueue { [self] in engine = nil }
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}

/// Read by the decode loop between tokens.
struct StopCheck: Sendable {
    let flags: RuntimeFlags
    let id: UUID
    let epoch: Int
    let deadline: ContinuousClock.Instant

    var shouldStop: Bool {
        if ContinuousClock.now >= deadline { return true }
        return flags.isStopped(id, epoch: epoch)
    }
}

/// Request ids cancelled before or while they run, and the unload epoch that stops a running decode.
final class RuntimeFlags: Sendable {
    private struct State {
        var cancelled: Set<UUID> = []
        var epoch = 0
    }

    private let state = Mutex(State())

    var epoch: Int { state.withLock { $0.epoch } }

    func cancel(_ id: UUID) {
        state.withLock {
            if $0.cancelled.count > 64 { $0.cancelled.removeAll() }
            $0.cancelled.insert(id)
        }
    }

    func forget(_ id: UUID) {
        state.withLock { _ = $0.cancelled.remove(id) }
    }

    func bumpEpoch() {
        state.withLock { $0.epoch += 1 }
    }

    func isStopped(_ id: UUID, epoch: Int) -> Bool {
        state.withLock { $0.cancelled.contains(id) || $0.epoch != epoch }
    }
}

enum LlamaBackend {
    private static let once: Void = {
        llama_backend_init()
        // llama.cpp logs to stderr by default, and a service has no use for it. Errors come back as throws.
        llama_log_set({ _, _, _ in }, nil)
    }()

    static func start() { _ = once }
}
