import AVFoundation
import Foundation
import SwiftData
import SwiftUI
import os

struct AudioRetranscriptionResult {
    let transcription: Transcription
    let enhancementFailure: String?
}

@MainActor
class AudioTranscriptionService: ObservableObject {
    @Published var isTranscribing = false
    @Published var currentError: TranscriptionError?

    private let modelContext: ModelContext
    private let enhancementService: AIEnhancementService?
    private let logger = Logger(subsystem: "com.techneissa.pnoe", category: "AudioTranscriptionService")
    private let serviceRegistry: TranscriptionServiceRegistry

    enum TranscriptionError: Error {
        case noAudioFile
        case transcriptionFailed
        case modelNotLoaded
        case invalidAudioFormat
    }

    init(modelContext: ModelContext, engine: PnoeEngine) {
        self.modelContext = modelContext
        self.enhancementService = engine.enhancementService
        self.serviceRegistry = TranscriptionServiceRegistry(
            modelProvider: engine.whisperModelManager, modelsDirectory: engine.whisperModelManager.modelsDirectory,
            modelContext: modelContext)
    }

    init(
        modelContext: ModelContext, serviceRegistry: TranscriptionServiceRegistry,
        enhancementService: AIEnhancementService?
    ) {
        self.modelContext = modelContext
        self.enhancementService = enhancementService
        self.serviceRegistry = serviceRegistry
    }

    func retranscribeAudio(from url: URL, using model: any TranscriptionModel, mode: ModeConfig? = nil) async throws
        -> AudioRetranscriptionResult
    {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.noAudioFile
        }

        await MainActor.run {
            isTranscribing = true
        }

        do {
            let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration
            let language = TranscriptionLanguageSupport.validLanguageOrFallback(
                mode?.selectedLanguage,
                for: model,
                realtimeEnabled: mode?.isRealtimeTranscriptionEnabled
            )
            let requestContext = TranscriptionRequestContext(
                language: language,
                prompt: model.provider == .whisper || model.provider == .whisperKit
                    ? WhisperPrompt.resolvedPrompt(for: language) : nil
            )
            let modeName = (mode?.isEnabled == true) ? mode?.name : nil
            let modeEmoji = (mode?.isEnabled == true) ? mode?.icon.value : nil

            let transcriptionStart = Date()
            var text = try await serviceRegistry.transcribe(audioURL: url, model: model, context: requestContext)
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)
            text = TranscriptionOutputFilter.filter(text)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let formattingConfiguration = ModeRuntimeResolver.transcriptionFormattingConfiguration(mode: mode)

            if formattingConfiguration.isTextFormattingEnabled {
                text = ParagraphFormatter.format(text)
            }

            // Same order as live dictation: replacements, then snippets; the model only sees placeholders.
            let snippets = SnippetProcessor.prepare(
                text,
                rules: SnippetService.rules(using: modelContext),
                applyingReplacements: {
                    WordReplacementService.shared.applyReplacements(to: $0, using: modelContext)
                }
            )
            text = snippets.textForEnhancement
            let cleanedText = snippets.expandedText

            let audioAsset = AVURLAsset(url: url)
            let duration = CMTimeGetSeconds(try await audioAsset.load(.duration))
            let recordingsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
                0
            ]
            .appendingPathComponent("com.techneissa.Pnoe")
            .appendingPathComponent("Recordings")

            let fileName = "retranscribed_\(UUID().uuidString).wav"
            let permanentURL = recordingsDirectory.appendingPathComponent(fileName)

            do {
                try FileManager.default.copyItem(at: url, to: permanentURL)
            } catch {
                logger.error("❌ Failed to create permanent copy of audio: \(error, privacy: .public)")
                isTranscribing = false
                throw error
            }

            let permanentURLString = permanentURL.absoluteString

            let originalText = cleanedText
            let enhancementConfiguration =
                enhancementService
                .flatMap { service in
                    service.getAIService().map { aiService in
                        ModeRuntimeResolver.currentEnhancementConfiguration(
                            mode: mode,
                            enhancementService: service,
                            aiService: aiService
                        )
                    }
                }

            // Apply AI enhancement if enabled
            if let enhancementService = enhancementService,
                let enhancementConfiguration,
                enhancementConfiguration.isEnabled,
                enhancementService.isConfigured(for: enhancementConfiguration),
                !snippets.skipsEnhancement
            {
                do {
                    let enhancementResult = try await enhancementService.enhance(
                        text,
                        configuration: enhancementConfiguration
                    )
                    let newTranscription = Transcription(
                        text: originalText,
                        duration: duration,
                        enhancedText: snippets.finish(enhanced: enhancementResult.text),
                        audioFileURL: permanentURLString,
                        transcriptionModelName: model.displayName,
                        aiEnhancementModelName: enhancementConfiguration.modelName
                            ?? enhancementConfiguration.provider?.defaultModel,
                        promptName: enhancementResult.promptName
                            ?? enhancementConfiguration.prompt?.title,
                        transcriptionDuration: transcriptionDuration,
                        enhancementDuration: enhancementResult.duration,
                        aiRequestSystemMessage: enhancementResult.systemMessage,
                        aiRequestUserMessage: enhancementResult.userMessage,
                        modeName: modeName,
                        modeEmoji: modeEmoji
                    )
                    modelContext.insert(newTranscription)
                    do {
                        try modelContext.save()
                        NotificationCenter.default.post(name: .transcriptionCreated, object: newTranscription)
                        NotificationCenter.default.post(name: .transcriptionCompleted, object: newTranscription)
                    } catch {
                        logger.error("❌ Failed to save transcription: \(error, privacy: .public)")
                    }
                    await MainActor.run {
                        isTranscribing = false
                    }

                    return AudioRetranscriptionResult(
                        transcription: newTranscription,
                        enhancementFailure: nil
                    )
                } catch {
                    let failureDescription = EnhancementFailureFormatter.description(for: error)
                    let failureMessage = EnhancementFailureFormatter.message(description: failureDescription)
                    let newTranscription = Transcription(
                        text: originalText,
                        duration: duration,
                        enhancedText: failureMessage,
                        audioFileURL: permanentURLString,
                        transcriptionModelName: model.displayName,
                        aiEnhancementModelName: enhancementConfiguration.modelName
                            ?? enhancementConfiguration.provider?.defaultModel,
                        promptName: enhancementConfiguration.prompt?.title,
                        transcriptionDuration: transcriptionDuration,
                        modeName: modeName,
                        modeEmoji: modeEmoji
                    )
                    modelContext.insert(newTranscription)
                    do {
                        try modelContext.save()
                        NotificationCenter.default.post(name: .transcriptionCreated, object: newTranscription)
                        NotificationCenter.default.post(name: .transcriptionCompleted, object: newTranscription)
                    } catch {
                        logger.error("❌ Failed to save transcription: \(error, privacy: .public)")
                    }

                    await MainActor.run {
                        isTranscribing = false
                    }

                    return AudioRetranscriptionResult(
                        transcription: newTranscription,
                        enhancementFailure: failureDescription
                    )
                }
            } else {
                let newTranscription = Transcription(
                    text: originalText,
                    duration: duration,
                    audioFileURL: permanentURLString,
                    transcriptionModelName: model.displayName,
                    promptName: nil,
                    transcriptionDuration: transcriptionDuration,
                    modeName: modeName,
                    modeEmoji: modeEmoji
                )
                modelContext.insert(newTranscription)
                do {
                    try modelContext.save()
                    NotificationCenter.default.post(name: .transcriptionCompleted, object: newTranscription)
                } catch {
                    logger.error("❌ Failed to save transcription: \(error, privacy: .public)")
                }

                await MainActor.run {
                    isTranscribing = false
                }

                return AudioRetranscriptionResult(
                    transcription: newTranscription,
                    enhancementFailure: nil
                )
            }
        } catch {
            logger.error("❌ Transcription failed: \(error, privacy: .public)")
            currentError = .transcriptionFailed
            isTranscribing = false
            throw error
        }
    }
}
