import Foundation

/// One protected stretch of tokens and the text it is written as.
struct Span {
    var range: Range<Int>
    var written: String
    var kind: ProtectedSpan.Kind
    /// Text that follows the span in the take but is not part of it ("'s" after an identifier).
    var suffix: String = ""
}

/// Finds the spans of a take that must reach the paste exactly. Categories run in the plan's order and the
/// first match wins: URLs and emails, files and paths, identifiers, versions, numbers, then vocabulary.
struct SpanFinder {
    let tokens: [Token]
    private let lower: [String]
    private var claimed: [Bool]
    private(set) var spans: [Span] = []

    init(tokens: [Token]) {
        self.tokens = tokens
        lower = tokens.map(\.lower)
        claimed = Array(repeating: false, count: tokens.count)
    }

    static func find(in tokens: [Token], vocabulary: [String]) -> [Span] {
        var finder = SpanFinder(tokens: tokens)
        finder.urlsAndEmails()
        finder.filesAndPaths()
        finder.identifiers()
        finder.versions()
        finder.numbers()
        finder.vocabulary(vocabulary)
        return finder.spans.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    // MARK: - Helpers

    private var count: Int { tokens.count }

    private func free(_ range: Range<Int>) -> Bool {
        range.lowerBound >= 0 && range.upperBound <= count && !claimed[range]
            .contains(true)
    }

    private mutating func claim(_ range: Range<Int>, _ written: String, _ kind: ProtectedSpan.Kind, suffix: String = "") {
        for i in range { claimed[i] = true }
        spans.append(Span(range: range, written: written, kind: kind, suffix: suffix))
    }

    /// No punctuation between the tokens of the range, so "slash." never joins a path.
    private func joined(_ range: Range<Int>) -> Bool {
        for i in range {
            if i > range.lowerBound, !tokens[i].lead.isEmpty { return false }
            if i < range.upperBound - 1, !tokens[i].trail.isEmpty { return false }
        }
        return true
    }

    private static let joinWords: Set<String> = ["dot", "slash", "underscore", "dash", "at", "tilde"]

    private func isNameWord(_ i: Int) -> Bool {
        guard i < count, !claimed[i] else { return false }
        let core = tokens[i].core
        return !core.isEmpty && !Self.joinWords.contains(lower[i])
            && core.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    /// word ("underscore"|"dash" word)*
    private func nameChain(at i: Int) -> (end: Int, text: String)? {
        guard isNameWord(i) else { return nil }
        var end = i + 1
        var text = tokens[i].core
        while end + 1 < count, tokens[end - 1].trail.isEmpty, tokens[end].trail.isEmpty, tokens[end].lead.isEmpty,
              tokens[end + 1].lead.isEmpty, lower[end] == "underscore" || lower[end] == "dash", isNameWord(end + 1) {
            text += (lower[end] == "underscore" ? "_" : "-") + tokens[end + 1].core
            end += 2
        }
        return (end, text)
    }

    private func fileName(at i: Int) -> (end: Int, text: String)? {
        guard let chain = nameChain(at: i), chain.end + 1 < count, lower[chain.end] == "dot",
              joined((chain.end - 1)..<(chain.end + 2)), !claimed[chain.end], !claimed[chain.end + 1],
              WordLists.fileExtensions.contains(lower[chain.end + 1]) else { return nil }
        return (chain.end + 2, chain.text + "." + lower[chain.end + 1])
    }

    private func segment(at i: Int) -> (end: Int, text: String, isFile: Bool)? {
        if let f = fileName(at: i) { return (f.end, f.text, true) }
        if let c = nameChain(at: i) { return (c.end, c.text, false) }
        return nil
    }

    // MARK: - 1. URLs and emails

    nonisolated(unsafe) private static let emailRegex = #/^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/#
    nonisolated(unsafe) private static let urlRegex = #/^(https?://|www\.)\S+$/#
    nonisolated(unsafe) private static let domainRegex = try! Regex("[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*\\.(" + WordLists.topLevelDomains.sorted().joined(separator: "|") + ")")

    private mutating func urlsAndEmails() {
        var i = 0
        while i < count {
            guard !claimed[i] else { i += 1; continue }
            let core = tokens[i].core
            if core.wholeMatch(of: Self.urlRegex) != nil {
                claim(i..<(i + 1), core, .url)
            } else if core.wholeMatch(of: Self.emailRegex) != nil {
                claim(i..<(i + 1), core, .email)
            } else if core.wholeMatch(of: Self.domainRegex) != nil {
                claim(i..<(i + 1), core, .url)
            } else if let m = spokenEmail(at: i) {
                claim(i..<m.end, m.text, .email)
            } else if let m = spokenDomain(at: i, allowPath: true) {
                claim(i..<m.end, m.text, .url)
            }
            i += 1
        }
    }

    /// label ("dot" label)+ with a known top-level domain last. The dot must precede a known TLD.
    private func domain(at i: Int) -> (end: Int, text: String)? {
        guard let first = nameChain(at: i) else { return nil }
        var end = first.end
        var text = first.text
        var best: (Int, String)?
        while end + 1 < count, lower[end] == "dot", joined((end - 1)..<(end + 2)), !claimed[end], let next = nameChain(at: end + 1) {
            text += "." + next.text
            end = next.end
            if WordLists.topLevelDomains.contains(next.text.lowercased()) { best = (end, text) }
        }
        return best.map { ($0.0, $0.1) }
    }

    private func spokenDomain(at i: Int, allowPath: Bool) -> (end: Int, text: String)? {
        guard var result = domain(at: i) else { return nil }
        guard allowPath else { return result }
        while result.end + 1 < count, lower[result.end] == "slash", joined((result.end - 1)..<(result.end + 2)),
              let seg = segment(at: result.end + 1) {
            result = (seg.end, result.text + "/" + seg.text)
        }
        return result
    }

    private func spokenEmail(at i: Int) -> (end: Int, text: String)? {
        guard let first = nameChain(at: i) else { return nil }
        var end = first.end
        var local = first.text
        while end + 1 < count, lower[end] == "dot", joined((end - 1)..<(end + 2)), let next = nameChain(at: end + 1) {
            local += "." + next.text
            end = next.end
        }
        guard end + 1 < count, lower[end] == "at", joined((end - 1)..<(end + 2)), !claimed[end],
              let dom = domain(at: end + 1) else { return nil }
        return (dom.end, local + "@" + dom.text)
    }

    // MARK: - 2. Files and paths

    private static let extensionAlternation = WordLists.fileExtensions.sorted().joined(separator: "|")
    nonisolated(unsafe) private static let pathRegex = #/^~?/?[A-Za-z0-9_.@+-]+(/[A-Za-z0-9_.@+-]+)+/?$/#
    nonisolated(unsafe) private static let rootedPathRegex = #/^~?/[A-Za-z0-9_.@+-]+/?$/#
    nonisolated(unsafe) private static let dotFileRegex = #/^\.[A-Za-z][A-Za-z0-9_.-]*$/#

    private static func isWrittenFileName(_ core: String) -> Bool {
        guard let dot = core.lastIndex(of: "."), dot != core.startIndex else { return false }
        let ext = core[core.index(after: dot)...].lowercased()
        let stem = core[..<dot]
        return WordLists.fileExtensions.contains(ext) && stem.last.map { $0.isLetter || $0.isNumber || $0 == "_" } == true
            && stem.allSatisfy { $0.isLetter || $0.isNumber || "_.-".contains($0) }
    }

    private mutating func filesAndPaths() {
        var i = 0
        while i < count {
            guard !claimed[i] else { i += 1; continue }
            let core = tokens[i].core
            if core.wholeMatch(of: Self.pathRegex) != nil || core.wholeMatch(of: Self.rootedPathRegex) != nil {
                claim(i..<(i + 1), core, .path)
            } else if Self.isWrittenFileName(core) || core.wholeMatch(of: Self.dotFileRegex) != nil {
                claim(i..<(i + 1), core, .fileName)
            } else if let p = spokenPath(at: i) {
                claim(i..<p.end, p.text, .path)
            } else if let f = fileName(at: i) {
                claim(i..<f.end, f.text, .fileName)
            }
            i += 1
        }
    }

    private func spokenPath(at i: Int) -> (end: Int, text: String)? {
        var j = i
        var prefix = ""
        var tilde = false
        if lower[i] == "tilde", i + 1 < count, lower[i + 1] == "slash", joined(i..<(i + 2)) {
            prefix = "~/"
            tilde = true
            j = i + 2
        } else if lower[i] == "slash", tokens[i].trail.isEmpty {
            prefix = "/"
            j = i + 1
        }
        guard j < count, let first = segment(at: j) else { return nil }
        var parts = [(first.text, first.isFile)]
        var end = first.end
        var joins = 0
        while end + 1 < count, lower[end] == "slash", joined((end - 1)..<(end + 2)), !claimed[end],
              let seg = segment(at: end + 1) {
            parts.append((seg.text, seg.isFile))
            end = seg.end
            joins += 1
        }
        guard joins >= 1 || tilde else { return nil }
        if parts.contains(where: { !$0.1 && WordLists.functionWords.contains($0.0.lowercased()) }) { return nil }
        return (end, prefix + parts.map(\.0).joined(separator: "/"))
    }

    // MARK: - 3. Code identifiers

    private static func isIdentifier(_ word: String) -> Bool {
        guard word.count >= 3 else { return false }
        if word.hasPrefix("--") { return word.count > 2 && word.dropFirst(2).allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }
        let chars = Array(word)
        guard chars.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), chars[0].isLetter else { return false }
        if word.contains("_") {
            let parts = word.split(separator: "_", omittingEmptySubsequences: false)
            return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty } && chars.contains(where: \.isLetter)
        }
        for k in 1..<chars.count {
            if (chars[k - 1].isLowercase || chars[k - 1].isNumber) && chars[k].isUppercase { return true }
            if k + 1 < chars.count, chars[k - 1].isUppercase, chars[k].isUppercase, chars[k + 1].isLowercase { return true }
        }
        return false
    }

    private mutating func identifiers() {
        var i = 0
        while i < count {
            guard !claimed[i] else { i += 1; continue }
            let core = tokens[i].core
            if core.hasPrefix("`") {
                if core.count >= 3, core.hasSuffix("`") {
                    claim(i..<(i + 1), core, .identifier)
                } else if let end = (i + 1..<min(count, i + 8)).first(where: { tokens[$0].core.hasSuffix("`") }), free(i..<(end + 1)) {
                    let text = (i...end).map { k in k == end ? tokens[k].core : tokens[k].core + tokens[k].trail }.joined(separator: " ")
                    claim(i..<(end + 1), text, .identifier)
                }
            } else {
                var base = core
                var suffix = ""
                for tail in ["'s", "’s"] where base.hasSuffix(tail) {
                    base.removeLast(tail.count)
                    suffix = tail
                }
                if Self.isIdentifier(base) { claim(i..<(i + 1), base, .identifier, suffix: suffix) }
            }
            i += 1
        }
    }

    // MARK: - 4. Versions

    nonisolated(unsafe) private static let versionRegex = #/^([vV]\d+(\.\d+)*|\d+(\.\d+){2,})$/#

    private mutating func versions() {
        for i in 0..<count where !claimed[i] && tokens[i].core.wholeMatch(of: Self.versionRegex) != nil {
            claim(i..<(i + 1), tokens[i].core, .version)
        }
    }

    // MARK: - 5. Numbers

    nonisolated(unsafe) private static let timeRegex = #/^\d{1,2}(:\d{2})?$/#
    nonisolated(unsafe) private static let plainNumberRegex = #/^\d[\d,]*(\.\d+)?$/#
    private static let units: Set<String> = [
        "minutes", "minute", "hours", "hour", "seconds", "second", "days", "day", "weeks", "week", "months", "month",
        "years", "year", "dollars", "dollar", "euros", "euro", "pounds", "cents", "bucks", "mb", "gb", "kb", "tb",
        "ms", "kg", "km", "miles", "mile", "meters", "meter", "feet", "inches", "px", "percent", "people", "items",
    ]
    private static let timePrepositions: Set<String> = ["at", "around", "by", "until", "till", "before", "after", "from", "about"]

    private func meridiem(at k: Int) -> String? {
        guard k < count, !claimed[k] else { return nil }
        switch lower[k].replacingOccurrences(of: ".", with: "") {
        case "am": return "AM"
        case "pm": return "PM"
        default: return nil
        }
    }

    /// The lowercased cores from `i`, stopping after the first token that carries punctuation.
    private func phrase(from i: Int, limit: Int = 10) -> [String] {
        var words: [String] = []
        var k = i
        while k < count, words.count < limit, !claimed[k] {
            if k > i, !tokens[k].lead.isEmpty { break }
            words.append(lower[k])
            if !tokens[k].trail.isEmpty { break }
            k += 1
        }
        return words
    }

    private func next(after end: Int) -> Int? {
        guard end < count, end > 0, tokens[end - 1].trail.isEmpty, tokens[end].lead.isEmpty, !claimed[end] else { return nil }
        return end
    }

    private mutating func numbers() {
        writtenDigits()
        var i = 0
        while i < count {
            guard !claimed[i] else { i += 1; continue }
            let words = phrase(from: i)
            if let seq = NumberWords.parseDigitSequence(words) {
                claim(i..<(i + seq.count), seq.digits, .number)
                i += seq.count
                continue
            }
            guard let (value, c) = NumberWords.parseCardinal(words) else { i += 1; continue }
            if let span = spokenNumber(at: i, value: value, tokenCount: c) {
                claim(i..<span.end, span.text, .number)
                i = span.end
            } else {
                i += c
            }
        }
    }

    private mutating func writtenDigits() {
        for i in 0..<count where !claimed[i] && tokens[i].core.contains(where: { $0.isASCII && $0.isNumber }) {
            let core = tokens[i].core
            if let j = next(after: i + 1), let ap = meridiem(at: j), core.wholeMatch(of: Self.timeRegex) != nil {
                claim(i..<(j + 1), core + " " + ap, .number)
            } else if let j = next(after: i + 1), lower[j] == "percent", core.wholeMatch(of: Self.plainNumberRegex) != nil {
                claim(i..<(j + 1), core + "%", .number)
            } else {
                claim(i..<(i + 1), core, .number)
            }
        }
    }

    private func spokenNumber(at i: Int, value: Int, tokenCount c: Int) -> (end: Int, text: String)? {
        let j = i + c
        let after = next(after: j)
        // Time with am/pm, or a bare "at six thirty".
        if (1...12).contains(value) {
            if let a = after, let ap = meridiem(at: a) { return (a + 1, "\(value) \(ap)") }
            if let a = after {
                if lower[a] == "oh", a + 1 < count, next(after: a + 1) != nil, let d = NumberWords.digit(lower[a + 1]), d != "0" {
                    return time(hour: value, minute: "0\(d)", end: a + 2, requireMeridiem: true)
                }
                if let (m, mc) = NumberWords.parseCardinal(phrase(from: a)), (10...59).contains(m) {
                    let preposition = i > 0 ? lower[i - 1] : ""
                    return time(hour: value, minute: String(m), end: a + mc, requireMeridiem: !Self.timePrepositions.contains(preposition))
                }
            }
        }
        // Decimal: "two point four".
        if let a = after, lower[a] == "point" {
            var digits = ""
            var k = a + 1
            while k < count, next(after: k) != nil, let d = NumberWords.digit(lower[k]) {
                digits.append(d)
                k += 1
            }
            if !digits.isEmpty {
                var text = "\(value).\(digits)"
                var end = k
                if let p = next(after: k), lower[p] == "percent" { text += "%"; end = p + 1 }
                return (end, text)
            }
        }
        if let a = after, lower[a] == "percent" { return (a + 1, NumberWords.format(value) + "%") }
        if value >= 2, let a = after, Self.units.contains(lower[a]) { return (j, NumberWords.format(value)) }
        if value >= 10 { return (j, NumberWords.format(value)) }
        return nil
    }

    /// "six" "thirty" "pm" to `6:30 PM`; with no meridiem only when the caller allowed a bare time.
    private func time(hour: Int, minute: String, end: Int, requireMeridiem: Bool) -> (end: Int, text: String)? {
        let mm = minute
        if let a = next(after: end), let ap = meridiem(at: a) { return (a + 1, "\(hour):\(mm) \(ap)") }
        if requireMeridiem { return nil }
        return (end, "\(hour):\(mm)")
    }

    // MARK: - 6. Vocabulary

    private mutating func vocabulary(_ terms: [String]) {
        let parsed = terms
            .map { term in (term, term.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }) }
            .filter { !$0.1.isEmpty }
            .sorted { $0.1.count > $1.1.count }
        for (canonical, words) in parsed {
            var i = 0
            while i + words.count <= count {
                let range = i..<(i + words.count)
                if free(range), joined(range) {
                    var matches = true
                    var suffix = ""
                    for (k, word) in words.enumerated() {
                        var core = lower[i + k]
                        if k == words.count - 1 {
                            for tail in ["'s", "’s"] where core.hasSuffix(tail) && core != word {
                                core.removeLast(tail.count)
                                suffix = tail
                            }
                        }
                        if core != word { matches = false; break }
                    }
                    if matches {
                        claim(range, canonical, .vocabulary, suffix: suffix)
                        i += words.count
                        continue
                    }
                }
                i += 1
            }
        }
    }
}
