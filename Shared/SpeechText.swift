import Foundation

/// Turns an Assistant reply into text a speech engine can read: Markdown markers removed, then cut into pieces
/// that fit one request to Ollama's speech endpoint.
enum SpeechText {
    /// The most characters one `POST /v1/audio/speech` request accepts as `input`.
    static let ollamaInputLimit = 4096

    /// The reply without Markdown: no heading, list, quote, table or emphasis markers, links and images reduced to
    /// their text, code blocks left out. Headings, list items and table rows end in a full stop so the engine pauses
    /// between them. Paragraphs stay separated by a blank line.
    static func plainText(fromMarkdown markdown: String) -> String {
        var paragraphs: [String] = []
        var current: [String] = []
        var inFence = false

        func endParagraph() {
            if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
            current = []
        }

        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                endParagraph()
                continue
            }
            if inFence { continue }
            if line.isEmpty {
                endParagraph()
                continue
            }
            if isRule(line) || isTableSeparator(line) {
                endParagraph()
                continue
            }

            var text = line
            var isBlock = false
            if let heading = stripped(text, pattern: #"^#{1,6}\s+"#) {
                text = heading
                isBlock = true
            }
            while text.hasPrefix(">") {
                text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if let item = stripped(text, pattern: #"^([-*+]|\d{1,9}[.)])\s+(\[[ xX]\]\s+)?"#) {
                text = item
                isBlock = true
            }
            if text.hasPrefix("|") {
                text = text.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }.joined(separator: ", ")
                isBlock = true
            }

            text = removeInlineMarkup(text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if isBlock {
                endParagraph()
                paragraphs.append(endsSentence(text) ? text : text + ".")
            } else {
                current.append(text)
            }
        }
        endParagraph()
        return paragraphs.joined(separator: "\n\n")
    }

    /// `text` cut into pieces of at most `limit` characters, at sentence ends. A sentence longer than the limit is
    /// cut at a space, and a word longer than the limit is cut anywhere. Counts Unicode scalars, which never
    /// undercounts what the server counts. Pieces are trimmed and none is empty.
    static func chunks(from text: String, limit: Int = ollamaInputLimit) -> [String] {
        precondition(limit > 0)
        var result: [String] = []
        var current = ""

        func flush() {
            let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { result.append(piece) }
            current = ""
        }

        for sentence in sentences(in: text) {
            if sentence.unicodeScalars.count > limit {
                flush()
                result.append(contentsOf: split(longSentence: sentence, limit: limit))
            } else if current.unicodeScalars.count + sentence.unicodeScalars.count > limit {
                flush()
                current = sentence
            } else {
                current += sentence
            }
        }
        flush()
        return result
    }

    // MARK: - Pieces

    private static func sentences(in text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { _, range, _, _ in
            result.append(String(text[range]))
        }
        return result
    }

    private static func split(longSentence sentence: String, limit: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        func flush() {
            let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            current = ""
        }
        for word in sentence.split(separator: " ", omittingEmptySubsequences: true) {
            var word = Substring(word)
            while word.unicodeScalars.count > limit {
                flush()
                pieces.append(string(of: word.unicodeScalars.prefix(limit)))
                word = Substring(string(of: word.unicodeScalars.dropFirst(limit)))
            }
            if current.unicodeScalars.count + word.unicodeScalars.count + 1 > limit { flush() }
            current += current.isEmpty ? String(word) : " " + word
        }
        flush()
        return pieces
    }

    private static func string(of scalars: some Sequence<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    // MARK: - Markdown

    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { !$0.isWhitespace }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        line.contains("-") && line.allSatisfy { "|-: ".contains($0) }
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return true }
        return ".!?:;…。！？".contains(last)
    }

    /// `text` without a leading match of `pattern`, or `nil` when it does not start with one.
    private static func stripped(_ text: String, pattern: String) -> String? {
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range.upperBound...])
    }

    private static let inlineRules: [(pattern: String, template: String)] = [
        (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),  // image: keep the alt text
        (#"\[([^\]]*)\]\([^)]*\)"#, "$1"),  // link: keep the label
        (#"\[([^\]]*)\]\[[^\]]*\]"#, "$1"),  // reference link
        (#"<(https?://[^>\s]+)>"#, "$1"),  // autolink
        (#"</?[A-Za-z][^>]*>"#, ""),  // HTML tag
        (#"`+([^`]*)`+"#, "$1"),  // inline code
        (#"(\*\*|__)(.+?)\1"#, "$2"),  // bold
        (#"~~(.+?)~~"#, "$1"),  // strikethrough
        (#"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, "$1"),  // italic with *
        (#"(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w_])"#, "$1"),  // italic with _
    ]

    private static func removeInlineMarkup(_ text: String) -> String {
        var result = text
        for rule in inlineRules {
            result = result.replacingOccurrences(of: rule.pattern, with: rule.template, options: .regularExpression)
        }
        return result.replacingOccurrences(of: #"\\([\\`*_{}\[\]()#+\-.!|>~])"#, with: "$1", options: .regularExpression)
    }
}
