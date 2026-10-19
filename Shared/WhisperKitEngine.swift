import Foundation

/// What the engine needs from WhisperKit. The app implements it with the real package; a test
/// implements it with a fake, so the loading and language rules run without a model.
protocol WhisperKitRunner: AnyObject, Sendable {
    /// Loads the Core ML model in `modelFolder`. `tokenizerBase` holds the tokenizer in the
    /// downloader's layout, so nothing is fetched at load time.
    func load(modelFolder: URL, tokenizerBase: URL) async throws
    func transcribe(audioURL: URL, language: String?, prompt: String?) async throws -> String
    func unload() async
}

enum WhisperKitEngineError: LocalizedError, Equatable {
    case modelNotInstalled(String)

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let name):
            return String(localized: "The WhisperKit model \(name) is not downloaded.")
        }
    }
}

/// Keeps one WhisperKit model loaded and runs takes through it.
///
/// Everything that touches the runner (load, take, unload) runs one at a time, in the order it was
/// asked for. That makes a preload and the first take share one load instead of loading twice, and
/// stops a delete from releasing the model under a take. A take whose task is cancelled stops
/// WhisperKit; `unload()` cancels the running take and waits for it before it releases the model.
actor WhisperKitEngine {
    private let storage: WhisperKitStorage
    private let makeRunner: @Sendable () -> any WhisperKitRunner
    private var runner: (any WhisperKitRunner)?
    private var loadedModelName: String?
    private var activeTake: Task<String, Error>?

    private var isBusy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(storage: WhisperKitStorage, makeRunner: @escaping @Sendable () -> any WhisperKitRunner) {
        self.storage = storage
        self.makeRunner = makeRunner
    }

    /// Whisper wants a bare language code. "auto", an empty choice or a regional tag such as
    /// "en-US" become nil (detect) or the base code.
    static func languageCode(from selected: String?) -> String? {
        guard let selected else { return nil }
        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed != "auto" else { return nil }
        return trimmed.split(separator: "-").first.map(String.init)
    }

    /// Loads the model ahead of the first take. A take that arrives meanwhile waits for this load.
    func load(_ spec: WhisperKitModelSpec) async throws {
        try await exclusive {
            try Task.checkCancellation()
            _ = try await loadedRunner(for: spec)
        }
    }

    /// Cancelling the calling task cancels the take, queued or running.
    func transcribe(
        audioURL: URL,
        spec: WhisperKitModelSpec,
        language: String?,
        prompt: String?
    ) async throws -> String {
        try Task.checkCancellation()
        return try await exclusive {
            try Task.checkCancellation()
            let runner = try await loadedRunner(for: spec)
            try Task.checkCancellation()

            let language = Self.languageCode(from: language)
            let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let take = Task { try await runner.transcribe(audioURL: audioURL, language: language, prompt: prompt) }
            activeTake = take
            defer { activeTake = nil }

            let text = try await withTaskCancellationHandler {
                try await take.value
            } onCancel: {
                take.cancel()
            }
            try Task.checkCancellation()
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Stops the running take, waits for the takes and loads ahead of it, then releases the model.
    func unload() async {
        activeTake?.cancel()
        try? await exclusive(cancellable: false) { await releaseRunner() }
    }

    // MARK: - Loading

    private func loadedRunner(for spec: WhisperKitModelSpec) async throws -> any WhisperKitRunner {
        if let runner, loadedModelName == spec.name { return runner }
        guard storage.isInstalled(spec) else {
            throw WhisperKitEngineError.modelNotInstalled(spec.displayName)
        }
        // A different model replaces the loaded one, so two never sit in memory together.
        await releaseRunner()
        let newRunner = makeRunner()
        do {
            try await newRunner.load(modelFolder: storage.modelFolder(for: spec), tokenizerBase: storage.base)
        } catch {
            await newRunner.unload()
            throw error
        }
        runner = newRunner
        loadedModelName = spec.name
        return newRunner
    }

    private func releaseRunner() async {
        let old = runner
        runner = nil
        loadedModelName = nil
        await old?.unload()
    }

    // MARK: - One at a time

    private func exclusive<T>(cancellable: Bool = true, _ body: () async throws -> T) async throws -> T {
        try await acquire(cancellable: cancellable)
        defer { release() }
        return try await body()
    }

    private func acquire(cancellable: Bool) async throws {
        if !isBusy {
            isBusy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append((id, continuation))
            }
        } onCancel: {
            if cancellable { Task { await self.cancelWaiter(id) } }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Hands the turn to the next waiter, or frees the engine when nobody waits.
    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
