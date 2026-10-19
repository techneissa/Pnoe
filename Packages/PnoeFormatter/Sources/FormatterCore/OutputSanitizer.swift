import Foundation

/// Step 6: strips what small models wrap around the answer. Works on the text with markers still in place.
/// Anything that looks like a structured wrapper it cannot unwrap is rejected, never pasted.
public enum OutputSanitizer {
    /// - Parameters:
    ///   - input: The text the model was given (markers in place). Quotes, preambles and sign-offs that the
    ///     input itself carries are kept.
    public static func sanitize(_ output: String, input: String) -> Result<String, FallbackReason> {
        var text = output
        text = stripThinkBlocks(text)
        text = stripFences(text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("{") {
            guard let unwrapped = unwrapJSON(text) else { return .failure(.wrapper) }
            text = unwrapped
        }

        text = dropPreamble(text, input: input)
        text = dropClosing(text, input: input)
        text = stripQuotes(text, input: input)
        text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        text = bulletsToDashes(text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return text.isEmpty ? .failure(.empty) : .success(text)
    }

    private static func stripThinkBlocks(_ text: String) -> String {
        var result = text.replacing(#/(?s)<think>.*?</think>/#, with: "")
        // An unclosed block swallows the rest.
        if let open = result.range(of: "<think>") { result.removeSubrange(open.lowerBound...) }
        return result.replacingOccurrences(of: "</think>", with: "")
    }

    private static func stripFences(_ text: String) -> String {
        guard text.contains("```") else { return text }
        var lines = text.components(separatedBy: "\n")
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        return lines.joined(separator: "\n")
    }

    private static func unwrapJSON(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.count == 1,
              let value = object["transcript"] as? String ?? object["text"] as? String else { return nil }
        return value
    }

    private static func inputStarts(_ input: String, with phrases: [String]) -> Bool {
        let lower = input.lowercased()
        return phrases.contains { lower.hasPrefix($0) }
    }

    private static let preambleStarts = ["here is", "here's", "here are", "sure", "certainly", "of course", "okay, here", "cleaned"]

    private static func dropPreamble(_ text: String, input: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.count > 1, let first = lines.first?.trimmingCharacters(in: .whitespaces).lowercased() else { return text }
        guard preambleStarts.contains(where: { first.hasPrefix($0) }), first.hasSuffix(":"),
              !inputStarts(input, with: preambleStarts) else { return text }
        lines.removeFirst()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let closingStarts = ["let me know", "i hope this", "feel free", "hope this helps"]

    private static func dropClosing(_ text: String, input: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.count > 1, let last = lines.last?.trimmingCharacters(in: .whitespaces).lowercased(),
              closingStarts.contains(where: { last.hasPrefix($0) }) else { return text }
        let inputLower = input.lowercased()
        if closingStarts.contains(where: { last.hasPrefix($0) && inputLower.contains($0) }) { return text }
        lines.removeLast()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let quotePairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’")]

    private static func stripQuotes(_ text: String, input: String) -> String {
        guard let first = text.first, let last = text.last, text.count >= 2 else { return text }
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in quotePairs where first == open && last == close {
            if trimmedInput.first == open { return text }
            return String(text.dropFirst().dropLast())
        }
        return text
    }

    /// Small models like "* item"; the notes style is "- item".
    private static func bulletsToDashes(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            let trimmed = line.drop(while: { $0 == " " })
            if trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") { return "- " + trimmed.dropFirst(2) }
            return line
        }.joined(separator: "\n")
    }
}
