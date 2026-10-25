import SwiftUI

/// The "Read Replies Aloud" switch with its help text and, while it is on, the voice picker for the source that will
/// speak: the voices the Ollama speech model lists, or the Apple voices installed in macOS. Lives apart from the
/// settings screen so it can be rendered on its own.
struct ReplySpeechSettingRows: View {
    @Binding var isEnabled: Bool
    @Binding var ollamaVoice: String
    @Binding var appleVoice: String
    /// Where replies will be spoken. Found by the settings screen when it appears.
    let engine: ReplySpeechEngine
    let appleVoices: [SpeechVoiceChoice]

    var body: some View {
        Group {
            Toggle("Read Replies Aloud", isOn: $isEnabled)

            Text("Speaks the Assistant's answer when it appears. Speech stops when you start recording, close the panel or press the stop button.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isEnabled {
                voicePicker
                    .motionFade()

                Text(sourceNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .motionFade()
            }
        }
        .motion(.reveal, value: isEnabled)
    }

    @ViewBuilder
    private var voicePicker: some View {
        switch engine {
        case .ollama(let model):
            Picker("Voice", selection: ollamaSelection(for: model)) {
                ForEach(model.voices, id: \.self) { voice in
                    Text(verbatim: voice).tag(voice)
                }
            }
        case .apple:
            Picker("Voice", selection: $appleVoice) {
                Text("Automatic").tag(ReplySpeechSettings.defaultAppleVoice)
                ForEach(appleVoices) { voice in
                    Text(verbatim: "\(voice.name) (\(voice.language))").tag(voice.id)
                }
            }
        }
    }

    /// The saved voice when the model still has it, so the picker never shows a choice that is not in its list.
    private func ollamaSelection(for model: OllamaSpeechModel) -> Binding<String> {
        Binding(
            get: { ReplySpeechSettings.effectiveOllamaVoice(saved: ollamaVoice, available: model.voices) },
            set: { ollamaVoice = $0 }
        )
    }

    private var sourceNote: String {
        switch engine {
        case .ollama(let model):
            return String(format: String(localized: "Voice from %@ through Ollama."), model.name)
        case .apple:
            return String(localized: "Using Apple voices. Install a speech model such as phonon in Ollama for a more natural voice.")
        }
    }
}

/// The round stop button next to the follow-up field, shown only while a reply is being read.
struct ReplySpeechStopButton: View {
    @ObservedObject var speaker: ReplySpeaker
    let ink: Color

    var body: some View {
        Group {
            if speaker.isSpeaking {
                Button {
                    speaker.stop(.stopButton)
                } label: {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(ink.opacity(0.88))
                        .frame(width: 24, height: 24)
                        .background(ink.opacity(0.10))
                        .clipShape(Circle())
                }
                .focusEffectDisabled()
                .buttonStyle(.plain)
                .help("Stop reading")
                .accessibilityLabel("Stop reading")
                .motionFade()
            }
        }
        .motion(.reveal, value: speaker.isSpeaking)
    }
}
