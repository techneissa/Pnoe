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

/// Keeps one WhisperKit model loaded and runs takes through it, one at a time.
actor WhisperKitEngine {
    private let storage: WhisperKitStorage
    private let makeRunner: @Sendable () -> any WhisperKitRunner
    private var runner: (any WhisperKitRunner)?
    private var loadedModelName: String?

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

    /// Loads the model ahead of the first take.
    func load(_ spec: WhisperKitModelSpec) async throws {
        _ = try await loadedRunner(for: spec)
    }

    func transcribe(
        audioURL: URL,
        spec: WhisperKitModelSpec,
        language: String?,
        prompt: String?
    ) async throws -> String {
        let runner = try await loadedRunner(for: spec)
        let text = try await runner.transcribe(
            audioURL: audioURL,
            language: Self.languageCode(from: language),
            prompt: prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unload() async {
        await runner?.unload()
        runner = nil
        loadedModelName = nil
    }

    private func loadedRunner(for spec: WhisperKitModelSpec) async throws -> any WhisperKitRunner {
        if let runner, loadedModelName == spec.name { return runner }
        guard storage.isInstalled(spec) else {
            throw WhisperKitEngineError.modelNotInstalled(spec.displayName)
        }
        // A different model replaces the loaded one, so two never sit in memory together.
        await unload()
        let runner = makeRunner()
        try await runner.load(modelFolder: storage.modelFolder(for: spec), tokenizerBase: storage.base)
        self.runner = runner
        loadedModelName = spec.name
        return runner
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
