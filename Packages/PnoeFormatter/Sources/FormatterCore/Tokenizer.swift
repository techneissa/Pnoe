import Foundation

/// One whitespace-separated piece of a take, split into leading punctuation, core and trailing punctuation.
/// Spoken-form matching works on cores so "dot py." still matches with the full stop kept outside the span.
struct Token: Equatable {
    var lead: String
    var core: String
    var trail: String

    var text: String { lead + core + trail }
    var lower: String { core.lowercased() }
}

enum Tokenizer {
    private static let leadChars: Set<Character> = ["(", "[", "{", "\"", "“", "‘"]
    private static let trailChars: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "\"", "”", "’", "…"]

    static func tokenize(_ text: String) -> [Token] {
        text.split(whereSeparator: \.isWhitespace).map { make(String($0)) }
    }

    static func make(_ piece: String) -> Token {
        var chars = Array(piece)
        var lead = ""
        var trail = ""
        while chars.count > 1, let first = chars.first, leadChars.contains(first) {
            lead.append(first)
            chars.removeFirst()
        }
        while chars.count > 1, let last = chars.last, trailChars.contains(last) {
            trail.insert(last, at: trail.startIndex)
            chars.removeLast()
        }
        return Token(lead: lead, core: String(chars), trail: trail)
    }

    static func render(_ tokens: [Token]) -> String {
        tokens.map(\.text).joined(separator: " ")
    }
}
