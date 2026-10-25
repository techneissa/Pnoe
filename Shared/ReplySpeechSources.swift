import Foundation

/// What can speak right now, for the settings screen: the engine `ReplySpeaker` would use, and the installed Apple
/// voices. Refreshed when the screen appears, because the person may have installed a speech model since.
@MainActor
final class ReplySpeechSources: ObservableObject {
    @Published private(set) var engine: ReplySpeechEngine = .apple
    @Published private(set) var appleVoices: [SpeechVoiceChoice] = []

    func refresh(
        ollama: OllamaSpeechProviding,
        appleVoices: @MainActor () -> [SpeechVoiceChoice] = SpeechVoiceChoice.installedAppleVoices
    ) async {
        self.appleVoices = appleVoices()
        engine = ReplySpeechEngine.choose(from: await ollama.speechModels())
    }
}
