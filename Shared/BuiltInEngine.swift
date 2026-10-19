import AppKit
import Dispatch
import FormatterCore
import FormatterModels
import FormatterXPC
import Foundation

/// What the Built-in engine reports for the workflows that are not Cleaned Text.
enum BuiltInEngineError: Error, Equatable {
    /// The chosen model is not on this Mac any more, or none was chosen.
    case modelMissing
    case timedOut
    case outputTooLong
    case failed(String)
}

/// The Built-in engine as the app uses it: one long-lived runtime that talks to the embedded XPC service,
/// shared by every workflow so the model stays loaded between takes. The runtime is `XPCFormatterRuntime`;
/// tests pass a `FakeRuntime`.
final class BuiltInEngine: @unchecked Sendable {
    /// The engine every workflow uses. The first use starts the memory-pressure watch and the unload at quit.
    static let shared: BuiltInEngine = {
        let engine = BuiltInEngine(runtime: BuiltInEngine.makeServiceRuntime())
        engine.unloadOnMemoryPressure()
        engine.unloadAtTermination()
        started = engine
        return engine
    }()

    /// The shared engine once something has used it; nil before. Code that only wants to free the model must
    /// not be the thing that starts the engine.
    private(set) nonisolated(unsafe) static var started: BuiltInEngine?

    /// The runtime every request goes through; it counts the requests in flight (a load or a generation).
    let runtime: any FormatterRuntime
    private let activity: ActivityCounter
    private let chosenFiles: @Sendable () -> [URL]
    private let artifact: @Sendable () -> FormatterModelArtifact
    private let catalog: @Sendable () -> FormatterModelCatalog.Configuration
    private var pressureSource: DispatchSourceMemoryPressure?

    init(
        runtime: any FormatterRuntime,
        chosenFiles: @escaping @Sendable () -> [URL] = { BuiltInEngine.storedChosenFiles() },
        artifact: @escaping @Sendable () -> FormatterModelArtifact = { .gemma4E2B() },
        catalog: @escaping @Sendable () -> FormatterModelCatalog.Configuration = { .init() }
    ) {
        let activity = ActivityCounter()
        self.activity = activity
        self.runtime = CountingRuntime(wrapping: runtime, activity: activity)
        self.chosenFiles = chosenFiles
        self.artifact = artifact
        self.catalog = catalog
    }

    private static func makeServiceRuntime() -> XPCFormatterRuntime {
        var configuration = XPCFormatterRuntime.Configuration()
        // A cold start loads about 3 GB. A take that would wait longer than this pastes the plain transcript,
        // and the load goes on in the service for the next take.
        configuration.maxPrepareWait = .seconds(12)
        return XPCFormatterRuntime(configuration: configuration)
    }

    // MARK: Models

    static func storedChosenFiles(defaults: UserDefaults = .standard) -> [URL] {
        (defaults.stringArray(forKey: BuiltInModels.chosenFilesKey) ?? []).map { URL(fileURLWithPath: $0) }
    }

    static func rememberChosenFile(_ url: URL, defaults: UserDefaults = .standard) {
        var paths = defaults.stringArray(forKey: BuiltInModels.chosenFilesKey) ?? []
        guard !paths.contains(url.path) else { return }
        paths.append(url.path)
        defaults.set(paths, forKey: BuiltInModels.chosenFilesKey)
    }

    /// The spec for a stored model id, nil when that model is gone.
    func spec(forModelID id: String) async -> RuntimeModelSpec? {
        await BuiltInModels.spec(forID: id, chosenFiles: chosenFiles(), artifact: artifact(), catalog: catalog())
    }

    // MARK: Free-form requests

    /// One system prompt and one user message, answered in full: the workflows that rewrite the text (Checklist,
    /// Summary and the others) go through here. Cleaned Text goes through `GuardedCleanup` instead.
    func complete(system: String, user: String, modelID: String, timeout: TimeInterval) async throws -> String {
        // One deadline for loading the model and generating.
        let deadline = ContinuousClock.now + .seconds(timeout)
        guard let spec = await spec(forModelID: modelID) else { throw BuiltInEngineError.modelMissing }
        let prefix = PromptPrefix(messages: [ChatMessage(role: .system, content: system)])
        do {
            try await runtime.prepare(spec, prefix: prefix, deadline: deadline)
            let request = GenerationRequest(
                suffix: [ChatMessage(role: .user, content: user)],
                maxTokens: 2048,
                deadline: deadline,
                prefixKey: prefix.key
            )
            let result = try await runtime.generate(request)
            switch result.stopReason {
            case .eos: return result.text
            case .cap: throw BuiltInEngineError.outputTooLong
            case .interrupted: throw BuiltInEngineError.timedOut
            }
        } catch let error as BuiltInEngineError {
            throw error
        } catch let error as FormatterRuntimeError {
            switch error {
            case .notReady: throw BuiltInEngineError.modelMissing
            case .cancelled, .modelLoading: throw BuiltInEngineError.timedOut
            case .crashed: throw BuiltInEngineError.failed(String(localized: "The Built-in engine stopped unexpectedly."))
            case .failed(let message): throw BuiltInEngineError.failed(message)
            }
        } catch is CancellationError {
            throw CancellationError()
        }
    }

    // MARK: Preload

    /// Starts loading the model of the workflow that is about to record, so the first take after an unload does
    /// not fall back. Only for a workflow that has AI on and uses Built-in. It never waits: the caller gets the
    /// task back (tests await it) and recording goes on. A load that fails or is refused is left for the take to
    /// find, which falls back as it does without a preload.
    @discardableResult
    func preloadIfUsed(isEnabled: Bool, providerName: String?, modelID: String?) -> Task<Void, Never>? {
        guard isEnabled, providerName == BuiltInModels.providerName, let modelID, !modelID.isEmpty else { return nil }
        let runtime = self.runtime
        return Task.detached(priority: .utility) { [self] in
            guard let spec = await spec(forModelID: modelID),
                let pipeline = try? FormatterPipeline.bundled(runtime: runtime)
            else { return }
            // The Cleaned Text prefix: a Cleaned Text take finds it ready, and any other template replaces only
            // the cached prefix, not the loaded model.
            try? await runtime.prepare(spec, prefix: pipeline.prefix, deadline: .now + .seconds(120))
        }
    }

    // MARK: Memory

    /// Frees the model when no workflow uses Built-in any more. Does nothing before the engine has been used.
    static func unloadIfUnused(workflows: [BuiltInUsage.Workflow]) {
        started?.applyUsage(workflows: workflows)
    }

    /// The model is freed once no workflow uses Built-in, but never under a request in flight (a dictation, or a
    /// Playground run on a workflow that is not set to Built-in): then the unload waits for the run to end. A
    /// workflow that uses Built-in again before that cancels the wait.
    func applyUsage(workflows: [BuiltInUsage.Workflow]) {
        if BuiltInUsage.isUsed(by: workflows) {
            activity.cancelPendingUnload()
        } else if !activity.requestUnloadWhenIdle(then: { [weak self] in self?.unloadInBackground() }) {
            unloadInBackground()
        }
    }

    private func unloadInBackground() {
        Task { await unload() }
    }

    /// Frees the model, and with it the service process, when the app quits.
    func unloadAtTermination() {
        let runtime = self.runtime
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            let done = DispatchSemaphore(value: 0)
            Task {
                await runtime.unload()
                done.signal()
            }
            _ = done.wait(timeout: .now() + 1)
        }
    }

    /// Frees the model when the system is short of memory. The next take loads it again.
    func unloadOnMemoryPressure() {
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        let runtime = self.runtime
        source.setEventHandler { Task { await runtime.unload() } }
        source.resume()
        pressureSource = source
    }

    func unload() async {
        await runtime.unload()
    }

    /// For tests: whether any request is in flight.
    var requestsInFlight: Int { activity.count }
}

/// How many requests are in flight, and an unload that is waiting for the last one.
final class ActivityCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private var pending: (@Sendable () -> Void)?

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return inFlight
    }

    func begin() {
        lock.lock()
        inFlight += 1
        lock.unlock()
    }

    func end() {
        lock.lock()
        inFlight -= 1
        let run = inFlight == 0 ? pending : nil
        if run != nil { pending = nil }
        lock.unlock()
        run?()
    }

    /// Returns false when nothing is in flight (the caller unloads now); otherwise keeps `action` for the end.
    func requestUnloadWhenIdle(then action: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard inFlight > 0 else { return false }
        pending = action
        return true
    }

    func cancelPendingUnload() {
        lock.lock()
        pending = nil
        lock.unlock()
    }
}

/// Counts a load or a generation as in flight for as long as it runs; everything else passes through.
final class CountingRuntime: FormatterRuntime, @unchecked Sendable {
    let id: FormatterRuntimeID
    private let base: any FormatterRuntime
    private let activity: ActivityCounter

    init(wrapping base: any FormatterRuntime, activity: ActivityCounter) {
        self.base = base
        self.activity = activity
        id = base.id
    }

    func prepare(_ spec: RuntimeModelSpec, prefix: PromptPrefix) async throws {
        activity.begin()
        defer { activity.end() }
        try await base.prepare(spec, prefix: prefix)
    }

    func prepare(_ spec: RuntimeModelSpec, prefix: PromptPrefix, deadline: ContinuousClock.Instant) async throws {
        activity.begin()
        defer { activity.end() }
        try await base.prepare(spec, prefix: prefix, deadline: deadline)
    }

    func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        activity.begin()
        defer { activity.end() }
        return try await base.generate(request)
    }

    func cancel(_ requestID: UUID) async { await base.cancel(requestID) }

    func unload() async { await base.unload() }
}

extension BuiltInEngineError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .modelMissing:
            String(localized: "The Built-in model isn't installed any more. Choose another model in the workflow.")
        case .timedOut:
            String(localized: "The Built-in model took too long. It may still be loading; try again in a moment.")
        case .outputTooLong:
            String(localized: "The Built-in model stopped before it finished the answer.")
        case .failed(let message):
            message
        }
    }
}
