import Foundation

/// Applies the "Use WhisperKit" setting to the model a take is about to run on.
@MainActor
enum WhisperKitEngineSelection {
    /// The model to run for `model`: the same model, or the fallback when the setting and the power
    /// state say WhisperKit should not run. Anything that is not a WhisperKit model is untouched, and
    /// WhisperKit stays when no other local model is installed.
    static func effectiveModel(
        for model: any TranscriptionModel,
        transcriptionModelManager: TranscriptionModelManager,
        defaults: UserDefaults = .standard,
        power: PowerSource = PowerSourceReader.current()
    ) -> any TranscriptionModel {
        guard model.provider == .whisperKit else { return model }

        let usage = WhisperKitUsage.stored(in: defaults)
        guard WhisperKitEnginePolicy.engine(usage: usage, power: power) == .fallback else { return model }

        let candidates = fallbackCandidates(in: transcriptionModelManager)
        let preferred = defaults.string(forKey: WhisperKitUsage.fallbackModelDefaultsKey)
        guard
            let key = WhisperKitEnginePolicy.fallbackModelName(
                preferred: preferred.flatMap { $0.isEmpty ? nil : $0 },
                usable: candidates.map(\.selectionKey)
            ),
            let fallback = candidates.first(where: { $0.selectionKey == key })
        else {
            return model
        }
        return fallback
    }

    /// Downloaded local models that can stand in for WhisperKit. Apple Speech comes last so the
    /// "first downloaded model" default prefers a model the user installed on purpose.
    static func fallbackCandidates(in manager: TranscriptionModelManager) -> [any TranscriptionModel] {
        let local = manager.usableModels.filter {
            switch $0.provider {
            case .whisper, .fluidAudio, .transcribeCpp, .nativeApple: true
            default: false
            }
        }
        return local.filter { $0.provider != .nativeApple } + local.filter { $0.provider == .nativeApple }
    }
}
