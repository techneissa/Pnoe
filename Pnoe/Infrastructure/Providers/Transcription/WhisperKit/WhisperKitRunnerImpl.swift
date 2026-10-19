import Foundation
import WhisperKit

/// Runs a Core ML Whisper model through the WhisperKit package.
final class WhisperKitRunnerImpl: WhisperKitRunner, @unchecked Sendable {
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

        let results = try await kit.transcribe(audioPath: audioURL.path, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
    }

    func unload() async {
        await kit?.unloadModels()
        kit = nil
    }
}
