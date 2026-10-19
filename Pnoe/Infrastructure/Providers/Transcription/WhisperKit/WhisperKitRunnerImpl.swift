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
        if let tokens = Self.promptTokens(for: prompt, tokenizer: kit.tokenizer) {
            options.promptTokens = tokens
        }

        // WhisperKit checks for task cancellation between windows and decoding steps.
        let results = try await kit.transcribe(audioPath: audioURL.path, decodeOptions: options)
        try Task.checkCancellation()
        return results.map(\.text).joined(separator: " ")
    }

    func transcribeLive(samples: [Float], language: String?, prompt: String?) async throws -> WhisperKitLiveResult {
        guard let kit else { throw PnoeEngineError.modelLoadFailed }
        try Task.checkCancellation()

        let languageCode = language.flatMap { Constants.languageCodes.contains($0) ? $0 : nil }
        // The caller keeps the window inside one Whisper window, so no chunking. No temperature
        // fallback either: a retry doubles the time of a pass, and the live line only needs a hint.
        var options = DecodingOptions(
            task: .transcribe,
            language: languageCode,
            temperatureFallbackCount: 0,
            detectLanguage: languageCode == nil,
            skipSpecialTokens: true
        )
        // Whisper reads at most 224 prompt tokens; keep the newest.
        if let tokens = Self.promptTokens(for: prompt, tokenizer: kit.tokenizer)?.suffix(223) {
            options.promptTokens = Array(tokens)
        }

        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        try Task.checkCancellation()
        let segments = results.flatMap(\.segments).map {
            WhisperKitLiveSegment(text: $0.text, start: Double($0.start), end: Double($0.end))
        }
        return WhisperKitLiveResult(segments: segments, language: results.first?.language)
    }

    private static func promptTokens(for prompt: String?, tokenizer: (any WhisperTokenizer)?) -> [Int]? {
        guard let prompt, let tokenizer else { return nil }
        let tokens = tokenizer.encode(text: " " + prompt)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        return tokens.isEmpty ? nil : tokens
    }

    func unload() async {
        let old = kit
        kit = nil
        await old?.unloadModels()
    }
}
