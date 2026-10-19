import Foundation

/// Step 2: takes under 4 words skip the model. Code fixes the first letter and "i", and adds a final period
/// to three-word takes outside chat.
public enum SkipRule {
    public static let minimumWords = 4

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }

    public static func shouldSkip(_ text: String) -> Bool {
        wordCount(text) < minimumWords
    }

    public static func format(_ text: String, context: FormatterContext) -> String {
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
        let words = wordCount(text)
        if context != .chat, words == 3, let last = tokens.last, !last.trail.contains(where: { [".", "?", "!", "…"].contains($0) }) {
            tokens[tokens.count - 1].trail += "."
        }
        return Tokenizer.render(tokens)
    }
}
