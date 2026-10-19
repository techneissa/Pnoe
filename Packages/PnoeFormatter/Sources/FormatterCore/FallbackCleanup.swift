import Foundation

/// The code-only cleanup a take gets when the model's text is not used (a failed guard, a timeout, a runtime
/// error): fillers are already gone by then, so this adds the first capital, "I", and a final period.
/// Nothing else changes, so the speaker's words stay as they were said.
public enum FallbackCleanup {
    private static let sentenceEnds: Set<Character> = [".", "?", "!", "…"]
    /// A take that ends in one of these pastes as it is: a period after `/etc/app.toml` would belong to the path.
    private static let noPeriodAfter: Set<ProtectedSpan.Kind> = [.url, .email, .path, .fileName, .identifier]

    /// The fallback for a take whose exact spans are already swapped for markers: capital, "I" and final
    /// period on the marker text, then the spans written back. A take ending in a path, URL, email, file name or
    /// identifier gets no period; one ending in a number does.
    public static func apply(_ protected: ProtectedText, context: FormatterContext) -> String {
        var endsInExactSpan = false
        if let last = Tokenizer.tokenize(protected.text).last,
            last.core.hasPrefix(String(TokenProtector.open)),
            let match = TokenProtector.markerMatches(in: last.core).first,
            let span = protected.spans.first(where: { $0.id == match.id })
        {
            endsInExactSpan = noPeriodAfter.contains(span.kind)
        }
        return protected.restore(render(protected.text, context: context, addPeriod: !endsInExactSpan))
    }

    /// For text with no spans to protect (or a caller that has none): same cleanup, always with a period.
    public static func apply(_ text: String, context: FormatterContext) -> String {
        render(text, context: context, addPeriod: true)
    }

    /// The whole fallback for a raw take: filler cleanup, protect, then `apply`. For a caller that has no pipeline.
    public static func clean(_ text: String, context: FormatterContext, vocabulary: [String] = []) -> String {
        let cleaned = FillerCleaner.clean(text, context: context)
        return apply(TokenProtector.protect(cleaned, vocabulary: vocabulary), context: context)
    }

    private static func render(_ text: String, context: FormatterContext, addPeriod: Bool) -> String {
        var tokens = Tokenizer.tokenize(text)
        guard !tokens.isEmpty else { return "" }
        for index in tokens.indices {
            let lower = tokens[index].lower
            if lower == "i" || lower.hasPrefix("i'") || lower.hasPrefix("i’") {
                tokens[index].core = "I" + tokens[index].core.dropFirst()
            }
        }
        // A first word with a capital inside it (iPhone, macOS, eBay) keeps its spelling.
        if let firstLetter = tokens[0].core.firstIndex(where: \.isLetter), firstLetter == tokens[0].core.startIndex,
            !tokens[0].core.dropFirst().contains(where: \.isUppercase)
        {
            tokens[0].core = tokens[0].core.prefix(1).uppercased() + tokens[0].core.dropFirst()
        }
        if addPeriod, context != .chat, let last = tokens.last, !last.trail.contains(where: { sentenceEnds.contains($0) }) {
            tokens[tokens.count - 1].trail += "."
        }
        return Tokenizer.render(tokens)
    }
}
