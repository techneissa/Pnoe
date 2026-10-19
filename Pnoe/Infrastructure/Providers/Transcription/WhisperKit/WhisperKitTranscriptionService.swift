import Foundation
import os

/// Routes WhisperKit models through the shared `WhisperKitEngine`.
final class WhisperKitTranscriptionService: TranscriptionService, @unchecked Sendable {
    private let engine: WhisperKitEngine
    private var observers: [NSObjectProtocol] = []
    private let logger = Logger(subsystem: "com.techneissa.pnoe", category: "WhisperKitTranscriptionService")

    init(
        storage: WhisperKitStorage = .default,
        makeRunner: @escaping @Sendable () -> any WhisperKitRunner = { WhisperKitRunnerImpl() }
    ) {
        engine = WhisperKitEngine(storage: storage, makeRunner: makeRunner)

        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: .whisperKitModelDeleted, object: nil, queue: nil) { [engine] _ in
                Task { await engine.unload() }
            }
        )
        observers.append(
            center.addObserver(forName: .didChangeModel, object: nil, queue: nil) { [engine] notification in
                // Free the Core ML model once the user picks something that is not a WhisperKit model.
                let name = notification.userInfo?["modelName"] as? String
                if name.flatMap(WhisperKitCatalog.spec(named:)) == nil {
                    Task { await engine.unload() }
                }
            }
        )
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func loadModel(for model: WhisperKitModel) async throws {
        guard let spec = model.spec else { throw unsupportedModelError(model.name) }
        try await engine.load(spec)
    }

    func transcribe(
        audioURL: URL,
        model: any TranscriptionModel,
        context: TranscriptionRequestContext
    ) async throws -> String {
        guard let whisperKitModel = model as? WhisperKitModel, let spec = whisperKitModel.spec else {
            throw unsupportedModelError(model.name)
        }
        logger.notice("Transcribing with WhisperKit model \(spec.name, privacy: .public)")
        return try await engine.transcribe(
            audioURL: audioURL,
            spec: spec,
            language: context.language,
            prompt: context.prompt
        )
    }

    func cleanup() {
        Task { [engine] in await engine.unload() }
    }

    private func unsupportedModelError(_ modelName: String) -> NSError {
        NSError(
            domain: "WhisperKitTranscriptionService",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "No WhisperKit model is registered for \(modelName)"]
        )
    }
}
