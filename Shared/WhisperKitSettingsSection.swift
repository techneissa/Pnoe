import SwiftUI

/// One model the user can pick as the stand-in for WhisperKit.
struct WhisperKitFallbackOption: Identifiable, Equatable {
    /// The model's selection key.
    let id: String
    let title: String
}

/// The "WhisperKit" section of the transcription settings: when to use WhisperKit and which model
/// takes over when it is not used. It holds no state of its own, so a test can render it offscreen.
struct WhisperKitSettingsSection<InfoButton: View>: View {
    @Binding var usage: WhisperKitUsage
    /// Empty means the first installed model.
    @Binding var fallbackModel: String
    let fallbackOptions: [WhisperKitFallbackOption]
    let power: PowerSource
    @ViewBuilder var infoButton: InfoButton

    private var activeFallbackTitle: String? {
        let name = WhisperKitEnginePolicy.fallbackModelName(
            preferred: fallbackModel.isEmpty ? nil : fallbackModel,
            usable: fallbackOptions.map(\.id)
        )
        return fallbackOptions.first { $0.id == name }?.title
    }

    private var statusText: String {
        let choice = WhisperKitEnginePolicy.engine(usage: usage, power: power)
        let powerText = power == .battery ? String(localized: "on battery") : String(localized: "on mains power")
        switch (usage, choice) {
        case (.on, _):
            return String(localized: "WhisperKit runs your WhisperKit model, on mains and on battery.")
        case (_, .whisperKit):
            return String(localized: "This Mac is \(powerText), so WhisperKit is used.")
        case (_, .fallback):
            guard let title = activeFallbackTitle else {
                return String(localized: "No other local model is downloaded, so WhisperKit is used.")
            }
            if usage == .off {
                return String(localized: "WhisperKit is off, so \(title) is used.")
            }
            return String(localized: "This Mac is \(powerText), so \(title) is used.")
        }
    }

    var body: some View {
        Section {
            LabeledContent {
                Picker("", selection: $usage) {
                    ForEach(WhisperKitUsage.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
            } label: {
                HStack(spacing: 4) {
                    Text("Use WhisperKit")
                    infoButton
                }
            }

            LabeledContent {
                Picker("", selection: $fallbackModel) {
                    Text("First downloaded model").tag("")
                    ForEach(fallbackOptions) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .labelsHidden()
                .disabled(usage == .on || fallbackOptions.isEmpty)
            } label: {
                Text("Model when WhisperKit is not used")
            }

            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
        } header: {
            Text("WhisperKit")
        }
    }
}
