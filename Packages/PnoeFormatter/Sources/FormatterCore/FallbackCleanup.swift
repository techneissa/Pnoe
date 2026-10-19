import Foundation

/// The code-only cleanup a take gets when the model's text is not used (a failed guard, a timeout, a runtime
/// error): fillers are already gone by then, so this adds the first capital, "I", and a final period.
/// Nothing else changes, so the speaker's words stay as they were said.
public enum FallbackCleanup {
    private static let sentenceEnds: Set<Character> = [".", "?", "!", "…"]

    /// Capitalizes the first letter and "I", and adds a period when the take does not end in `.`, `?`, `!`
    /// or `…`. Chat takes get no final period, like short chat takes in `SkipRule`.
    public static func apply(_ text: String, context: FormatterContext) -> String {
        var tokens = Tokenizer.tokenize(text)
        guard !tokens.isEmpty else { return "" }
        for index in tokens.indices {
            let lower = tokens[index].lower
            if lower == "i" || lower.hasPrefix("i'") || lower.hasPrefix("i’") {
                tokens[index].core = "I" + tokens[index].core.dropFirst()
            }
        }
        if let firstLetter = tokens[0].core.firstIndex(where: \.isLetter), firstLetter == tokens[0].core.startIndex {
            tokens[0].core = tokens[0].core.prefix(1).uppercased() + tokens[0].core.dropFirst()
        }
        if context != .chat, let last = tokens.last, !last.trail.contains(where: { sentenceEnds.contains($0) }) {
            tokens[tokens.count - 1].trail += "."
        }
        return Tokenizer.render(tokens)
    }

    /// The whole fallback for a raw take: filler cleanup, then `apply`. For a caller that has no pipeline.
    public static func clean(_ text: String, context: FormatterContext) -> String {
        apply(FillerCleaner.clean(text, context: context), context: context)
    }
}
