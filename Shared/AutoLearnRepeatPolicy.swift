import Foundation

/// How many identical corrections Auto Learn waits for before it saves a pair.
enum AutoLearnRepeatThreshold: Int, CaseIterable, Identifiable, Sendable {
    case immediately = 1
    case twice = 2
    case three = 3
    case four = 4
    case five = 5

    /// Two repeats keep a one-off fix (a typo, a different word chosen once) out of the
    /// dictionary and still learn a real habit quickly.
    static let `default`: AutoLearnRepeatThreshold = .twice

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .immediately: String(localized: "Immediately")
        case .twice: String(localized: "After 2 corrections")
        case .three: String(localized: "After 3 corrections")
        case .four: String(localized: "After 4 corrections")
        case .five: String(localized: "After 5 corrections")
        }
    }

    func isReached(by count: Int) -> Bool { count >= rawValue }
}

/// Decides which edits are worth counting. A correction that only changes case or punctuation, a
/// sentence rewritten from scratch or a long phrase says little about how a word is heard, and
/// saving it would clutter the dictionary.
enum CorrectionNoiseFilter {
    /// The most words on either side of a pair. A name or a short phrase passes; a clause does not.
    static let maximumWords = 4
    static let maximumCharacters = 48
    /// When the edit replaces everything that was pasted, only a pair this short counts. A longer
    /// one is a rewrite, not a correction.
    static let maximumWordsForWholeTextEdit = 2

    static func isLearnable(heard: String, corrected: String, pastedText: String) -> Bool {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !corrected.isEmpty else { return false }

        for side in [heard, corrected] {
            guard wordCount(side) <= maximumWords,
                side.count <= maximumCharacters,
                !side.contains(where: \.isNewline),
                !isMultiSentence(side)
            else { return false }
        }

        guard letters(heard) != letters(corrected) else { return false }

        let isWholeText = letters(heard) == letters(pastedText)
        if isWholeText,
            max(wordCount(heard), wordCount(corrected)) > maximumWordsForWholeTextEdit
        {
            return false
        }
        return true
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// Words that end in a full stop without ending a sentence: "St. John", "Dr. Who".
    private static let abbreviations: Set<String> = [
        "st", "mr", "mrs", "ms", "dr", "jr", "sr", "vs", "etc", "e.g", "i.e", "no",
    ]

    /// Sentence punctuation, quotes, brackets and dashes. Only these are ignored, and only at the
    /// edge of a word; a symbol that is part of the word ("c#", "50%", "@name") is kept.
    private static let edgePunctuation = CharacterSet(charactersIn: ".,!?;:…。\"'“”‘’()[]{}«»-–—")

    /// True when a sentence ending is followed by more text: "Fix this. Then that." A full stop
    /// after an abbreviation or an initial ("St.", "J.", "U.S.") does not end a sentence.
    private static func isMultiSentence(_ text: String) -> Bool {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        for (index, token) in tokens.enumerated().dropLast() {
            guard tokens[(index + 1)...].contains(where: { $0.contains(where: { $0.isLetter || $0.isNumber }) })
            else { continue }
            if endsSentence(token) { return true }
        }
        return false
    }

    private static func endsSentence(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’)]}»"))
        guard let last = trimmed.last, ".!?…。".contains(last) else { return false }
        guard last == "." else { return true }
        let word = String(trimmed.dropLast()).lowercased()
        if abbreviations.contains(word) { return false }
        // Initials such as "J." or "U.S.": every dot-separated part is one letter.
        let parts = word.split(separator: ".", omittingEmptySubsequences: false)
        return !(!word.isEmpty && parts.allSatisfy { $0.count == 1 && $0.first!.isLetter })
    }

    /// The text without case or edge punctuation and with single spaces, so "Hello,  world."
    /// equals "hello world", "open a i" stays different from "OpenAI" and "c++" from "c#".
    private static func letters(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: edgePunctuation) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }
}

/// Which review runs may start on their own. Corrections queued before the repeat count existed
/// wait for the user when "Review with AI" is off.
enum AutoLearnReviewTrigger {
    case automatic
    case explicit

    func isAllowed(usesAIReview: Bool) -> Bool {
        switch self {
        case .automatic: usesAIReview
        case .explicit: true
        }
    }
}

/// Fields whose text must never be read for learning.
enum AutoLearnFieldGuard {
    static let secureSubrole = "AXSecureTextField"

    static func isSecure(subrole: String?) -> Bool {
        subrole == secureSubrole
    }
}
