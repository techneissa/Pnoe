import Foundation
import SwiftData

/// A transcript after word replacements and snippet matching, ready for the model: what dictation and the
/// Workflows Playground both start from.
struct PreparedTranscript {
    let snippets: SnippetPreparedText
    /// The text with snippet triggers as placeholders. This is what the model sees when the result is pasted.
    let textForEnhancement: String
    /// The transcript with snippet expansions, pasted when no model runs.
    var transcript: String { snippets.expandedText }
    let skipsEnhancement: Bool
    let respondInRecorder: Bool

    /// Respond mode pastes nothing and the model needs the snippet content, so it gets the expanded text;
    /// a paste gets placeholders.
    var textForAI: String { respondInRecorder ? transcript : textForEnhancement }

    /// The text to paste once the model has answered: snippets go back in, last.
    func finalText(enhanced: String) -> String {
        respondInRecorder ? enhanced : snippets.finish(enhanced: enhanced)
    }

    static func make(
        _ text: String,
        modelContext: ModelContext,
        respondInRecorder: Bool,
        defaults: UserDefaults = .standard
    ) -> PreparedTranscript {
        // Snippets match after word replacements. Their expansions stay out of the text until
        // after enhancement, so neither replacements nor the model touch them.
        let snippets = SnippetProcessor.prepare(
            text,
            rules: SnippetService.rules(using: modelContext),
            applyingReplacements: {
                WordReplacementService.shared.applyReplacements(to: $0, using: modelContext)
            }
        )
        let skips = EnhancementSkipPolicy.shouldSkip(
            snippetsOnly: snippets.skipsEnhancement,
            respondInRecorder: respondInRecorder,
            skipShortEnabled: defaults.bool(forKey: "SkipShortEnhancement"),
            wordCount: WordCounter.count(in: snippets.textForEnhancement),
            threshold: EnhancementSkipPolicy.threshold(saved: defaults.integer(forKey: "ShortEnhancementWordThreshold"))
        )
        return PreparedTranscript(
            snippets: snippets,
            textForEnhancement: snippets.textForEnhancement,
            skipsEnhancement: skips,
            respondInRecorder: respondInRecorder)
    }
}

extension AIEnhancementService {
    /// Whether the model runs for this take: AI is on for the workflow, the provider is set up and the take
    /// is not skipped. When it does not, the transcript is pasted as it is.
    func runsEnhancement(for prepared: PreparedTranscript, configuration: EnhancementRuntimeConfiguration) -> Bool {
        configuration.isEnabled && isConfigured(for: configuration) && !prepared.skipsEnhancement
    }

    /// The one call that turns a prepared transcript into the text dictation pastes. The model's answer comes
    /// back with the final text, snippets restored.
    func enhanceTranscript(
        _ prepared: PreparedTranscript,
        configuration: EnhancementRuntimeConfiguration,
        contextSnapshot: RecordingContextSnapshot? = nil
    ) async throws -> (result: AIEnhancementResult, finalText: String) {
        let result = try await enhance(prepared.textForAI, configuration: configuration, contextSnapshot: contextSnapshot)
        return (result, prepared.finalText(enhanced: result.text))
    }
}
