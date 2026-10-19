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

    /// True when a sentence ending and a space are followed by more text: "Fix this. Then that."
    /// "U.S.A" and "e.g." do not count, because no space follows the full stop.
    private static func isMultiSentence(_ text: String) -> Bool {
        var afterTerminator = false
        var afterSpace = false
        for character in text {
            if ".!?…。".contains(character) {
                afterTerminator = true
                afterSpace = false
            } else if character.isWhitespace {
                afterSpace = afterTerminator
            } else if character.isLetter || character.isNumber {
                if afterTerminator && afterSpace { return true }
                afterTerminator = false
            }
        }
        return false
    }

    /// The text without case or punctuation and with single spaces, so "Hello,  world." equals
    /// "hello world" but "open a i" stays different from "OpenAI".
    private static func letters(_ text: String) -> String {
        let kept = text.unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
        }
        return String(String.UnicodeScalarView(kept))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }
}

/// Fields whose text must never be read for learning.
enum AutoLearnFieldGuard {
    static let secureSubrole = "AXSecureTextField"

    static func isSecure(subrole: String?) -> Bool {
        subrole == secureSubrole
    }
}
