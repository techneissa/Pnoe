import Foundation
import WhisperKit

/// Runs a Core ML Whisper model through the WhisperKit package.
///
/// An actor owns the `WhisperKit` object, so a load, a take and an unload never touch it from two
/// threads. A take keeps its own reference, so an unload during a take cannot free it underneath.
actor WhisperKitRunnerImpl: WhisperKitRunner {
    private var kit: WhisperKit?

    func load(modelFolder: URL, tokenizerBase: URL) async throws {
        // `download: false` and a local folder keep WhisperKit from touching the network; the
        // tokenizer is already in `tokenizerBase`.
        let config = WhisperKitConfig(
            downloadBase: tokenizerBase,
            modelFolder: modelFolder.path,
            tokenizerFolder: tokenizerBase,
            verbose: false,
            logLevel: .none,
            prewarm: false,
            load: true,
            download: false
        )
        kit = try await WhisperKit(config)
    }

    func transcribe(audioURL: URL, language: String?, prompt: String?) async throws -> String {
        guard let kit else { throw PnoeEngineError.modelLoadFailed }
        try Task.checkCancellation()

        let languageCode = language.flatMap { Constants.languageCodes.contains($0) ? $0 : nil }
        var options = DecodingOptions(
            task: .transcribe,
            language: languageCode,
            detectLanguage: languageCode == nil,
            skipSpecialTokens: true,
            chunkingStrategy: .vad
        )
        if let prompt, let tokenizer = kit.tokenizer {
            let tokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            if !tokens.isEmpty { options.promptTokens = tokens }
        }

        // WhisperKit checks for task cancellation between windows and decoding steps.
        let results = try await kit.transcribe(audioPath: audioURL.path, decodeOptions: options)
        try Task.checkCancellation()
        return results.map(\.text).joined(separator: " ")
    }

    func unload() async {
        let old = kit
        kit = nil
        await old?.unloadModels()
    }
}
