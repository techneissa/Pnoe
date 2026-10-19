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
    /// The engine every workflow uses.
    static let shared = BuiltInEngine(runtime: BuiltInEngine.makeServiceRuntime())

    let runtime: any FormatterRuntime
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
        self.runtime = runtime
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
        guard let spec = await spec(forModelID: modelID) else { throw BuiltInEngineError.modelMissing }
        let prefix = PromptPrefix(messages: [ChatMessage(role: .system, content: system)])
        do {
            try await runtime.prepare(spec, prefix: prefix)
            let request = GenerationRequest(
                suffix: [ChatMessage(role: .user, content: user)],
                maxTokens: 2048,
                deadline: .now + .seconds(timeout)
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

    // MARK: Memory

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
