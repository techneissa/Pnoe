import Foundation

/// One saved snippet: a spoken trigger phrase and the text that replaces it.
struct SnippetRule: Equatable, Sendable {
    let trigger: String
    let expansion: String
}

/// How triggers are compared. Used by matching, the duplicate check and backup import so all three agree.
enum SnippetTrigger {
    /// What a transcriber (or a typed trigger) puts around a phrase: sentence punctuation and quotes.
    /// Characters that can belong to a trigger itself (`#`, `%`, `+`, brackets) are kept.
    private static let edgePunctuation = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ".,;:!?…\"'“”„‘’«»"))

    /// Trims whitespace, sentence punctuation and quotes at the edges, collapses inner whitespace and composes accents.
    static func normalized(_ trigger: String) -> String {
        trigger
            .trimmingCharacters(in: edgePunctuation)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .precomposedStringWithCanonicalMapping
    }

    /// Case-insensitive identity of a trigger.
    static func key(_ trigger: String) -> String {
        normalized(trigger).lowercased()
    }

    /// A trigger needs at least one letter or digit, or it could never be told apart from punctuation.
    static func isUsable(_ trigger: String) -> Bool {
        normalized(trigger).unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}

/// Result of looking for snippet triggers in a transcript.
///
/// Matched triggers are swapped for opaque placeholders so later stages (AI enhancement) cannot
/// rewrite the expansion. `restore(in:)` puts the expansions back verbatim.
struct SnippetMatchResult: Equatable, Sendable {
    /// The text with every matched trigger replaced by a placeholder.
    let protectedText: String
    /// Expansion for each placeholder, by index.
    let expansions: [String]
    /// True when nothing but snippet triggers (and punctuation) was spoken.
    let isSnippetOnly: Bool

    var hasMatches: Bool { !expansions.isEmpty }

    static func unchanged(_ text: String) -> SnippetMatchResult {
        SnippetMatchResult(protectedText: text, expansions: [], isSnippetOnly: false)
    }

    /// The final text with every expansion inserted.
    var expandedText: String { restore(in: protectedText) }

    static func placeholder(_ index: Int) -> String { "⟦snippet-\(index)⟧" }

    private static let placeholderPattern = try! NSRegularExpression(pattern: "⟦snippet-([0-9]+)⟧")

    private static func placeholderIndices(in text: String) -> [Int] {
        let range = NSRange(text.startIndex..., in: text)
        return placeholderPattern.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) }
        }
    }

    /// True when every placeholder appears exactly once, which is how we know a model left them alone.
    func isIntact(in text: String) -> Bool {
        let found = Self.placeholderIndices(in: text)
        return found.count == expansions.count && Set(found) == Set(expansions.indices)
    }

    /// Swaps placeholders for expansions in a single pass, so an expansion is never scanned again.
    func restore(in text: String) -> String {
        guard hasMatches else { return text }
        let range = NSRange(text.startIndex..., in: text)
        var output = ""
        var cursor = text.startIndex
        for match in Self.placeholderPattern.matches(in: text, range: range) {
            guard let whole = Range(match.range, in: text),
                let digits = Range(match.range(at: 1), in: text),
                let index = Int(text[digits]), expansions.indices.contains(index)
            else { continue }
            output += text[cursor..<whole.lowerBound]
            output += expansions[index]
            cursor = whole.upperBound
        }
        output += text[cursor...]
        return output
    }
}

/// Finds snippet triggers in a transcript.
///
/// A trigger matches as a whole phrase, ignoring case. Capitals and punctuation the transcriber puts
/// around it are tolerated ("My email." matches "my email"), and so is a comma or period between
/// its words. It matches alone or inside a sentence, but never inside a longer word. When two
/// triggers overlap, the longer one wins.
enum SnippetMatcher {
    private struct Candidate {
        let range: Range<String.Index>
        let ruleIndex: Int
        let length: Int
    }

    private static let wordCharacter = "[[\\p{L}\\p{M}\\p{N}]-[\\p{scx=Han}\\p{scx=Hiragana}\\p{scx=Katakana}\\p{scx=Hangul}\\p{scx=Thai}]]"
    private static let unspacedScripts: [ClosedRange<UInt32>] = [
        0x3040...0x309F, 0x30A0...0x30FF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0x0E00...0x0E7F,
    ]

    static func match(in text: String, rules: [SnippetRule]) -> SnippetMatchResult {
        var seenKeys = Set<String>()
        var usable: [(rule: SnippetRule, regex: NSRegularExpression, length: Int)] = []
        for rule in rules where SnippetTrigger.isUsable(rule.trigger) && !rule.expansion.isEmpty {
            guard seenKeys.insert(SnippetTrigger.key(rule.trigger)).inserted,
                let regex = regex(for: rule.trigger)
            else { continue }
            usable.append((rule, regex, SnippetTrigger.normalized(rule.trigger).count))
        }
        guard !usable.isEmpty, !text.isEmpty else { return .unchanged(text) }

        let fullRange = NSRange(text.startIndex..., in: text)
        var candidates: [Candidate] = []
        for (index, entry) in usable.enumerated() {
            for match in entry.regex.matches(in: text, range: fullRange) {
                guard let range = Range(match.range, in: text), !range.isEmpty else { continue }
                candidates.append(Candidate(range: range, ruleIndex: index, length: entry.length))
            }
        }

        // Longest trigger first, then earliest; drop anything that overlaps one already taken.
        candidates.sort {
            if $0.length != $1.length { return $0.length > $1.length }
            return $0.range.lowerBound < $1.range.lowerBound
        }
        var accepted: [Candidate] = []
        for candidate in candidates
        where !accepted.contains(where: { $0.range.overlaps(candidate.range) }) {
            accepted.append(candidate)
        }
        guard !accepted.isEmpty else { return .unchanged(text) }
        accepted.sort { $0.range.lowerBound < $1.range.lowerBound }

        var protectedText = ""
        var leftover = ""
        var expansions: [String] = []
        var cursor = text.startIndex
        for candidate in accepted {
            let before = text[cursor..<candidate.range.lowerBound]
            protectedText += before
            leftover += before
            protectedText += SnippetMatchResult.placeholder(expansions.count)
            expansions.append(usable[candidate.ruleIndex].rule.expansion)
            cursor = candidate.range.upperBound
        }
        let tail = text[cursor...]
        protectedText += tail
        leftover += tail

        // Only triggers were spoken: drop the punctuation the transcriber added around them.
        let isSnippetOnly = !leftover.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        if isSnippetOnly {
            protectedText = expansions.indices.map(SnippetMatchResult.placeholder).joined(separator: " ")
        }
        return SnippetMatchResult(protectedText: protectedText, expansions: expansions, isSnippetOnly: isSnippetOnly)
    }

    private static func regex(for trigger: String) -> NSRegularExpression? {
        let normalized = SnippetTrigger.normalized(trigger)
        let usesWordBoundaries = !normalized.unicodeScalars.contains { scalar in
            unspacedScripts.contains { $0.contains(scalar.value) }
        }

        let words = normalized.split(separator: " ").map { word in
            word.map { character -> String in
                character == "'" || character == "’"
                    ? "['’]" : NSRegularExpression.escapedPattern(for: String(character))
            }.joined()
        }
        // A transcriber may put a comma or period between spoken words ("sig, block").
        let separator = usesWordBoundaries ? "[,.;:!?]?\\s+" : "\\s*"
        var pattern = words.joined(separator: separator)
        if usesWordBoundaries {
            pattern = "(?<!\(wordCharacter))\(pattern)(?!\(wordCharacter))"
        }
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}

/// Runs the snippet step of the transcript pipeline in the one order that keeps expansions safe:
/// word replacements first, then trigger matching, and the expansion goes back in last.
struct SnippetPreparedText: Equatable, Sendable {
    let match: SnippetMatchResult

    /// Text to hand to AI enhancement: triggers are placeholders it must leave alone.
    var textForEnhancement: String { match.protectedText }

    /// The transcript with expansions inserted (what is saved when no enhancement runs).
    var expandedText: String { match.expandedText }

    /// A transcript that is only snippet triggers has nothing left for a model to improve.
    var skipsEnhancement: Bool { match.isSnippetOnly }

    /// Puts expansions back into the enhanced text. If the model dropped or duplicated a
    /// placeholder, the expansions cannot be placed safely, so the un-enhanced text wins.
    func finish(enhanced: String) -> String {
        guard match.hasMatches else { return enhanced }
        return match.isIntact(in: enhanced) ? match.restore(in: enhanced) : expandedText
    }
}

enum SnippetProcessor {
    static func prepare(
        _ text: String,
        rules: [SnippetRule],
        applyingReplacements replace: (String) -> String
    ) -> SnippetPreparedText {
        SnippetPreparedText(match: SnippetMatcher.match(in: replace(text), rules: rules))
    }
}
