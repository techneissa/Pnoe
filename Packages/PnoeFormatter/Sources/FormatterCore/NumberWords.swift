import Foundation

/// Spoken numbers to digits, in code. "One" to "nine" alone stay words; the caller decides when a small
/// number sits next to a unit, percent, am/pm or "point" and needs digits.
public enum NumberWords {
    private static let units: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    private static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
        "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = ["thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]

    private enum Kind { case unit, teen, tens, hundred, scale, and }

    public static func isNumberWord(_ word: String) -> Bool {
        units[word] != nil || teens[word] != nil || tens[word] != nil || word == "hundred" || scales[word] != nil
    }

    /// Parses the longest cardinal at the start of `words` (lowercased tokens; "twenty-one" is one token).
    /// Returns the value and the number of tokens used. "zero" is not a cardinal here.
    public static func parseCardinal(_ words: [String]) -> (value: Int, count: Int)? {
        var total = 0
        var current = 0
        var lastScale = Int.max
        var previous: Kind?
        var accepted = 0
        var index = 0
        outer: while index < words.count {
            let word = words[index]
            let parts = word.contains("-") ? word.split(separator: "-").map(String.init) : [word]
            var trial = (total, current, lastScale, previous)
            let lookahead = index + 1 < words.count ? words[index + 1] : nil
            for part in parts {
                if !step(part, state: &trial, lookahead: lookahead) { break outer }
            }
            (total, current, lastScale, previous) = trial
            index += 1
            if previous != .and { accepted = index }
        }
        guard accepted > 0 else { return nil }
        // Recompute for the accepted tokens only (a trailing "and" is not part of the number).
        if index != accepted { return parseCardinal(Array(words[..<accepted])) }
        return (total + current, accepted)
    }

    private static func step(
        _ word: String,
        state: inout (Int, Int, Int, Kind?),
        lookahead: String?
    ) -> Bool {
        var (total, current, lastScale, previous) = state
        defer { state = (total, current, lastScale, previous) }
        if let v = units[word] {
            guard previous == nil || previous == .hundred || previous == .scale || previous == .tens || previous == .and else { return false }
            current += v
            previous = .unit
        } else if let v = teens[word] {
            guard previous == nil || previous == .hundred || previous == .scale || previous == .and else { return false }
            current += v
            previous = .teen
        } else if let v = tens[word] {
            guard previous == nil || previous == .hundred || previous == .scale || previous == .and else { return false }
            current += v
            previous = .tens
        } else if word == "hundred" {
            guard previous == .unit, (1...9).contains(current) else { return false }
            current *= 100
            previous = .hundred
        } else if let scale = scales[word] {
            guard let p = previous, p != .scale, p != .and, current > 0, scale < lastScale else { return false }
            total += current * scale
            current = 0
            lastScale = scale
            previous = .scale
        } else if word == "and" {
            guard previous == .hundred || previous == .scale, let next = lookahead,
                  units[next] != nil || teens[next] != nil || tens[next] != nil else { return false }
            previous = .and
        } else {
            return false
        }
        return true
    }

    private static let digitWords: [String: Character] = [
        "zero": "0", "oh": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
        "seven": "7", "eight": "8", "nine": "9",
    ]

    /// One digit word ("one" to "nine", "zero", "oh") as a character.
    public static func digit(_ word: String) -> Character? { digitWords[word] }

    /// A run of three or more digit words ("four oh two") becomes a digit string. It needs an "oh" or "zero",
    /// or seven or more words (a phone number), so "one two three" in a list stays words.
    public static func parseDigitSequence(_ words: [String]) -> (digits: String, count: Int)? {
        var digits = ""
        var hasZero = false
        for word in words {
            guard let d = digitWords[word] else { break }
            if word == "zero" || word == "oh" { hasZero = true }
            digits.append(d)
        }
        guard digits.count >= 3, hasZero || digits.count >= 7 else { return nil }
        return (digits, digits.count)
    }

    /// Digits for a spoken value. Thousands get commas; years from 1900 to 2099 that are not round hundreds do not.
    public static func format(_ value: Int) -> String {
        guard value >= 1_000, !((1900...2099).contains(value) && value % 100 != 0) else { return String(value) }
        var digits = Array(String(value))
        var out: [Character] = []
        while digits.count > 3 {
            out.insert(contentsOf: [","] + digits.suffix(3), at: 0)
            digits.removeLast(3)
        }
        return String(digits + out)
    }
}
