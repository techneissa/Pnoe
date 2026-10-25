import AVFoundation
import Foundation
import NaturalLanguage

/// Plays streamed samples through `AVAudioEngine`: each network chunk is queued as a buffer, so the first one plays
/// while the rest is still being made.
@MainActor
final class EnginePCMOutput: PCMStreamOutput {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: PCMSampleDecoder.sampleRate, channels: 1, interleaved: false)!
    private var queuedBuffers = 0
    private var isStopped = false
    private var drainWaiter: CheckedContinuation<Void, Never>?

    func start() throws {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()
        node.play()
    }

    func enqueue(_ samples: [Float]) {
        guard !isStopped, !samples.isEmpty,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        queuedBuffers += 1
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.bufferFinished() }
        }
    }

    func waitUntilDrained() async {
        guard !isStopped, queuedBuffers > 0 else { return }
        await withCheckedContinuation { drainWaiter = $0 }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        node.stop()
        engine.stop()
        queuedBuffers = 0
        resumeWaiter()
    }

    private func bufferFinished() {
        guard !isStopped else { return }
        queuedBuffers -= 1
        if queuedBuffers <= 0 { resumeWaiter() }
    }

    private func resumeWaiter() {
        drainWaiter?.resume()
        drainWaiter = nil
    }
}

/// Speaks with `AVSpeechSynthesizer`.
@MainActor
final class AppleSpeechSynthesizerOutput: NSObject, AppleSpeechOutput, AVSpeechSynthesizerDelegate {
    /// Made on the first reply, so a Mac that never reads aloud never starts one.
    private var synthesizer: AVSpeechSynthesizer?
    private var waiter: CheckedContinuation<Void, Never>?

    func speak(_ text: String, voiceIdentifier: String?) async {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(identifier: voiceIdentifier, text: text)
        let synthesizer = self.synthesizer ?? makeSynthesizer()
        await withCheckedContinuation { continuation in
            waiter = continuation
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        if let synthesizer, synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        resumeWaiter()
    }

    private func makeSynthesizer() -> AVSpeechSynthesizer {
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        self.synthesizer = synthesizer
        return synthesizer
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resumeWaiter() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resumeWaiter() }
    }

    private func resumeWaiter() {
        waiter?.resume()
        waiter = nil
    }

    /// The chosen voice, or one for the language of the text, or `nil` (the system voice).
    private static func voice(identifier: String?, text: String) -> AVSpeechSynthesisVoice? {
        if let identifier, let voice = AVSpeechSynthesisVoice(identifier: identifier) { return voice }
        guard let language = NLLanguageRecognizer.dominantLanguage(for: text) else { return nil }
        return AVSpeechSynthesisVoice(language: language.rawValue)
    }
}

/// A voice in the picker.
struct SpeechVoiceChoice: Identifiable, Equatable, Sendable {
    /// The Apple voice identifier.
    let id: String
    let name: String
    let language: String

    /// The voices installed in macOS, without the novelty ones, by name.
    @MainActor
    static func installedAppleVoices() -> [SpeechVoiceChoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.identifier.contains(".speech.synthesis.voice.") }
            .map { voice in
                let language = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
                return SpeechVoiceChoice(id: voice.identifier, name: voice.name, language: language)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

extension ReplySpeaker {
    /// The speaker the app uses: Ollama at the saved address, then Apple voices.
    static func live(defaults: UserDefaults = .standard) -> ReplySpeaker {
        ReplySpeaker(
            defaults: defaults,
            ollama: { OllamaSpeechService(baseURL: ReplySpeechSettings.ollamaBaseURL(defaults: defaults)) },
            makeOutput: { EnginePCMOutput() },
            apple: AppleSpeechSynthesizerOutput()
        )
    }
}
