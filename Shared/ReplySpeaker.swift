import Foundation
import os

/// Where a reply is spoken: through Ollama's speech model, or with the Apple voices built into macOS.
enum ReplySpeechEngine: Equatable, Sendable {
    case ollama(OllamaSpeechModel)
    case apple

    /// Ollama when an installed model has the `speech` capability (the first of `models`), Apple voices otherwise.
    static func choose(from models: [OllamaSpeechModel]) -> ReplySpeechEngine {
        models.first.map(ReplySpeechEngine.ollama) ?? .apple
    }
}

/// Why speech ended. The reasons that end it at once are the ones that would let the microphone hear Pnoe's voice.
enum ReplySpeechStopReason: Equatable {
    case recordingStarted
    case panelClosed
    case stopButton
    /// A new question or a new answer replaced the one being read.
    case replaced
}

/// Plays raw 24 kHz mono samples as they arrive.
@MainActor
protocol PCMStreamOutput: AnyObject {
    func start() throws
    func enqueue(_ samples: [Float])
    /// Returns once every queued sample has played, or `stop()` was called.
    func waitUntilDrained() async
    func stop()
}

/// Speaks text with an Apple voice.
@MainActor
protocol AppleSpeechOutput: AnyObject {
    /// Returns once the text has been spoken, or `stop()` was called.
    func speak(_ text: String, voiceIdentifier: String?) async
    func stop()
}

/// Reads the Assistant's replies aloud when the setting is on. It starts when a reply arrives and ends at once on
/// `stop(_:)`: a recording starting, the panel closing, or the stop control. While it speaks, `isSpeaking` is true.
///
/// With an Ollama speech model installed, the reply is cut at sentence ends, sent piece by piece, and each piece starts
/// playing while the rest of it is still arriving. Without one, or when Ollama fails before any audio, the Apple
/// voices read the reply.
@MainActor
final class ReplySpeaker: ObservableObject {
    @Published private(set) var isSpeaking = false

    /// Asked before speech starts; the engine answers `false` while a recording is starting or running, so the
    /// microphone never records Pnoe's voice.
    var canStart: () -> Bool = { true }

    private let defaults: UserDefaults
    private let ollama: () -> OllamaSpeechProviding
    private let makeOutput: () -> PCMStreamOutput
    private let apple: AppleSpeechOutput
    private let logger = Logger(subsystem: "com.techneissa.pnoe", category: "ReplySpeaker")

    private var task: Task<Void, Never>?
    private var output: PCMStreamOutput?
    private var generation = 0

    init(
        defaults: UserDefaults = .standard,
        ollama: @escaping () -> OllamaSpeechProviding,
        makeOutput: @escaping () -> PCMStreamOutput,
        apple: AppleSpeechOutput
    ) {
        self.defaults = defaults
        self.ollama = ollama
        self.makeOutput = makeOutput
        self.apple = apple
    }

    /// Speaks `markdown` when the setting is on, there is something to say, and nothing is being recorded. Whatever was
    /// being read stops first.
    func speakIfEnabled(_ markdown: String) {
        stop(.replaced)
        guard ReplySpeechSettings.isEnabled(defaults: defaults), canStart() else { return }
        let text = SpeechText.plainText(fromMarkdown: markdown)
        guard !text.isEmpty else { return }

        generation += 1
        let id = generation
        isSpeaking = true
        task = Task { [weak self] in
            await self?.run(text: text)
            guard let self, self.generation == id else { return }
            self.isSpeaking = false
            self.output = nil
            self.task = nil
        }
    }

    func stop(_ reason: ReplySpeechStopReason) {
        generation += 1
        task?.cancel()
        task = nil
        output?.stop()
        output = nil
        apple.stop()
        isSpeaking = false
    }

    // MARK: - Speaking

    private func run(text: String) async {
        let service = ollama()
        let models = await service.speechModels()
        guard !Task.isCancelled else { return }

        switch ReplySpeechEngine.choose(from: models) {
        case .apple:
            await speakWithApple(text)
        case .ollama(let model):
            let voice = ReplySpeechSettings.effectiveOllamaVoice(
                saved: ReplySpeechSettings.ollamaVoice(defaults: defaults), available: model.voices)
            var playedAudio = false
            do {
                try await speakWithOllama(text, service: service, model: model.name, voice: voice) { playedAudio = true }
            } catch is CancellationError {
                return
            } catch {
                logger.error("Ollama speech failed: \(String(describing: error), privacy: .public)")
                // Nothing was heard yet: let the Apple voices read it instead of staying silent.
                self.output?.stop()
                self.output = nil
                if !playedAudio, !Task.isCancelled { await speakWithApple(text) }
            }
        }
    }

    private func speakWithOllama(
        _ text: String, service: OllamaSpeechProviding, model: String, voice: String, onAudio: () -> Void
    ) async throws {
        let output = makeOutput()
        self.output = output
        try output.start()

        for piece in SpeechText.chunks(from: text) {
            var decoder = PCMSampleDecoder()
            for try await bytes in service.audio(model: model, input: piece, voice: voice) {
                try Task.checkCancellation()
                let samples = decoder.decode(bytes)
                guard !samples.isEmpty else { continue }
                onAudio()
                output.enqueue(samples)
            }
            try Task.checkCancellation()
        }
        await output.waitUntilDrained()
    }

    private func speakWithApple(_ text: String) async {
        // No saved voice: the output picks one that fits the language of the text.
        let saved = ReplySpeechSettings.appleVoice(defaults: defaults)
        await apple.speak(text, voiceIdentifier: saved.isEmpty ? nil : saved)
    }
}
