import Foundation

/// Start values for the word-diff guard; Gate B tunes them. Per-context values follow the plan's table.
public struct WordDiffThresholds: Sendable, Equatable {
    public var minLengthRatio: Double = 0.40
    public var maxLengthRatio: Double = 1.30
    /// Inputs under this many words use `shortInputSlack` instead of the ratio.
    public var shortInputWords: Int = 10
    public var shortInputSlack: Int = 3
    /// New content words as a share of the output's content words.
    public var maxNewWordRatio: Double
    /// Share of the input's content words (after allowed removals) the output must keep.
    public var minRecall: Double
    /// A run of this many consecutive missing input words fails.
    public var maxMissingRun: Int

    public init(maxNewWordRatio: Double, minRecall: Double, maxMissingRun: Int) {
        self.maxNewWordRatio = maxNewWordRatio
        self.minRecall = minRecall
        self.maxMissingRun = maxMissingRun
    }

    public static func defaults(for context: FormatterContext) -> WordDiffThresholds {
        switch context {
        case .agent: WordDiffThresholds(maxNewWordRatio: 0.10, minRecall: 0.90, maxMissingRun: 3)
        case .chat: WordDiffThresholds(maxNewWordRatio: 0.15, minRecall: 0.70, maxMissingRun: 4)
        case .email: WordDiffThresholds(maxNewWordRatio: 0.25, minRecall: 0.70, maxMissingRun: 4)
        case .notes, .plain: WordDiffThresholds(maxNewWordRatio: 0.20, minRecall: 0.70, maxMissingRun: 4)
        }
    }
}

/// The numbers behind a verdict, so the eval harness can tune thresholds from data.
public struct WordDiffReport: Sendable, Equatable {
    public var inputWords: Int
    public var outputWords: Int
    public var newContentRatio: Double
    public var recall: Double
    public var longestMissingRun: Int
    public var reason: FallbackReason?
}

/// Step 8: compares the restored output with the written-out input and rejects drift. Lowercases, strips
/// punctuation and aligns words by longest common subsequence. It is also the injection guard: an answered
/// request has near-zero recall.
public enum WordDiffGuard {
    public static func check(
        input: String,
        output: String,
        context: FormatterContext,
        thresholds: WordDiffThresholds? = nil
    ) -> FallbackReason? {
        evaluate(input: input, output: output, context: context, thresholds: thresholds).reason
    }

    public static func evaluate(
        input: String,
        output: String,
        context: FormatterContext,
        thresholds: WordDiffThresholds? = nil
    ) -> WordDiffReport {
        let t = thresholds ?? .defaults(for: context)
        let (inWords, outWords) = alignedWords(input: input, output: output)
        var report = WordDiffReport(
            inputWords: inWords.count, outputWords: outWords.count,
            newContentRatio: 0, recall: 1, longestMissingRun: 0, reason: nil
        )

        // Length.
        if inWords.count < t.shortInputWords {
            if abs(outWords.count - inWords.count) > t.shortInputSlack { report.reason = .length }
        } else {
            let ratio = Double(outWords.count) / Double(inWords.count)
            if ratio < t.minLengthRatio || ratio > t.maxLengthRatio { report.reason = .length }
        }

        // Alignment.
        let (matchedIn, matchedOut) = align(inWords, outWords)
        let outContent = outWords.indices.filter { !WordLists.stopwords.contains(outWords[$0]) }
        let newContent = outContent.filter { !matchedOut[$0] }.count
        report.newContentRatio = outContent.isEmpty ? 0 : Double(newContent) / Double(outContent.count)
        if report.reason == nil, report.newContentRatio > t.maxNewWordRatio { report.reason = .newWords }

        let removable = allowedRemovals(inWords, output: output)
        let inContent = inWords.indices.filter { !WordLists.stopwords.contains(inWords[$0]) && !removable.contains($0) }
        if !inContent.isEmpty {
            report.recall = Double(inContent.filter { matchedIn[$0] }.count) / Double(inContent.count)
        }
        if report.reason == nil, report.recall < t.minRecall { report.reason = .dropped }

        report.longestMissingRun = longestMissingRun(inWords, matched: matchedIn, removable: removable)
        if report.reason == nil, report.longestMissingRun >= t.maxMissingRun { report.reason = .droppedSpan }

        if report.reason == nil { report.reason = invented(input: input, output: output, inWords: inWords) }
        if report.reason == nil, containsNewMeta(inWords: inWords, outWords: outWords) { report.reason = .meta }
        if report.reason == nil { report.reason = questionRules(input: input, inWords: inWords, output: output, outWords: outWords) }
        return report
    }

    // MARK: - Words

    nonisolated(unsafe) private static let listMarker = #/^\s*(\d+[.)]|[-•*])\s+/#

    /// Words of a text, one array of parts per whitespace token ("heads-up" gives ["heads", "up"]).
    private static func tokens(of text: String) -> [[String]] {
        var result: [[String]] = []
        for line in text.components(separatedBy: "\n") {
            let body = line.replacing(listMarker, with: "")
            for piece in body.split(whereSeparator: \.isWhitespace) {
                let normalized = piece.lowercased().replacingOccurrences(of: "’", with: "'")
                let parts = normalized.split(whereSeparator: { "-–—".contains($0) })
                    .map { WordTools.trimEdges(String($0)) }
                    .filter { !$0.isEmpty }
                if !parts.isEmpty { result.append(parts) }
            }
        }
        return result
    }

    static func words(of text: String) -> [String] {
        tokens(of: text).flatMap { $0 }
    }

    private static let digitNames: [String: String] = [
        "1": "one", "2": "two", "3": "three", "4": "four", "5": "five", "6": "six", "7": "seven", "8": "eight", "9": "nine",
    ]

    /// Words of both sides, made comparable: a hyphenated compound matches its closed form on the other side
    /// ("Wi-Fi" and "wifi"), and a digit 1 to 9 matches the number word the speaker said ("5" and "five").
    private static func alignedWords(input: String, output: String) -> (input: [String], output: [String]) {
        let inTokens = tokens(of: input)
        let outTokens = tokens(of: output)
        let inVocabulary = Set(inTokens.map { $0.joined() })
        let outVocabulary = Set(outTokens.map { $0.joined() })
        func merge(_ tokens: [[String]], other: Set<String>) -> [String] {
            tokens.flatMap { parts in
                parts.count > 1 && other.contains(parts.joined()) ? [parts.joined()] : parts
            }
        }
        let inWords = merge(inTokens, other: outVocabulary)
        var outWords = merge(outTokens, other: inVocabulary)
        let inSet = Set(inWords)
        for (i, word) in outWords.enumerated() {
            if let name = digitNames[word], inSet.contains(name), !inSet.contains(word) { outWords[i] = name }
        }
        return (inWords, outWords)
    }

    /// Longest-common-subsequence alignment. Returns which input and output positions are matched.
    private static func align(_ a: [String], _ b: [String]) -> (inMatched: [Bool], outMatched: [Bool]) {
        let n = a.count
        let m = b.count
        var inMatched = Array(repeating: false, count: n)
        var outMatched = Array(repeating: false, count: m)
        guard n > 0, m > 0 else { return (inMatched, outMatched) }
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var i = 0
        var j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                inMatched[i] = true
                outMatched[j] = true
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return (inMatched, outMatched)
    }

    // MARK: - Allowed removals

    private static let ordinalCues: Set<String> = ["first", "second", "third", "fourth", "fifth", "sixth"]
    nonisolated(unsafe) private static let numberedLine = #/(?m)^\s*\d+[.)]\s/#

    /// Input positions the output may drop without penalty: fillers, spoken-command words, correction
    /// markers with the 1 to 4 words before them, list cues once the output is a numbered list, and
    /// openers like "okay so" at the start.
    static func allowedRemovals(_ words: [String], output: String) -> Set<Int> {
        var removable: Set<Int> = []
        for (i, word) in words.enumerated() {
            if WordLists.fillerWords.contains(word) || WordLists.commandWords.contains(word) { removable.insert(i) }
        }
        for phrase in WordLists.commandPhrases + WordLists.fillerPhrases + WordLists.softCorrectionPhrases {
            for i in words.indices where CorrectionMarkers.matches(phrase, in: words, at: i) {
                for k in i..<(i + phrase.count) { removable.insert(k) }
            }
        }
        let regions = CorrectionMarkers.regions(in: words)
        removable.formUnion(regions.markers)
        removable.formUnion(regions.window)
        if output.contains(numberedLine) {
            for (i, word) in words.enumerated() where ordinalCues.contains(word) { removable.insert(i) }
        }
        var i = 0
        while i < min(3, words.count), WordLists.leadingMarkers.contains(words[i]) {
            removable.insert(i)
            i += 1
        }
        // "12,500 dollars" written as `$12,500`: the spoken unit word has become the symbol.
        let written = writtenCurrency(in: Array(output))
        for index in words.indices.dropLast() {
            guard let symbol = spokenUnits[words[index + 1]], let amount = amountKey(words[index]) else { continue }
            if written.contains(CurrencyAmount(symbol: symbol, amount: amount)) { removable.insert(index + 1) }
        }
        return removable
    }

    private static func longestMissingRun(_ words: [String], matched: [Bool], removable: Set<Int>) -> Int {
        var longest = 0
        var run = 0
        var hasContent = false
        for i in words.indices {
            if matched[i] {
                run = 0
                hasContent = false
            } else if removable.contains(i) {
                continue
            } else {
                run += 1
                if !WordLists.stopwords.contains(words[i]) { hasContent = true }
                if hasContent { longest = max(longest, run) }
            }
        }
        return longest
    }

    // MARK: - New numbers, currency, meta

    nonisolated(unsafe) private static let digitRun = #/\d+/#

    private static func invented(input: String, output: String, inWords: [String]) -> FallbackReason? {
        let outputBody = output.components(separatedBy: "\n").map { $0.replacing(listMarker, with: "") }.joined(separator: "\n")
        if hasInventedCurrency(input: input, output: outputBody) { return .inventedCurrency }
        // Digits in the input, plus the digit of any number word the speaker said ("five" allows "5").
        var known = Set(input.matches(of: digitRun).map { String($0.output) })
        for (digit, name) in digitNames where inWords.contains(name) { known.insert(digit) }
        if outputBody.matches(of: digitRun).contains(where: { !known.contains(String($0.output)) }) { return .newNumber }
        return nil
    }

    // MARK: Currency

    /// A unit word the speaker can say after an amount, and the symbol it may become.
    private static let spokenUnits: [String: Character] = [
        "dollar": "$", "dollars": "$", "buck": "$", "bucks": "$",
        "pound": "£", "pounds": "£", "euro": "€", "euros": "€", "yen": "¥",
    ]

    private static func isCurrencySymbol(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.properties.generalCategory == .currencySymbol }
    }

    private struct CurrencyAmount: Hashable {
        var symbol: Character
        var amount: String
    }

    /// Every currency symbol in the output must sit on an amount, and the input must give that same symbol
    /// that same amount: written with the symbol, or said with its unit word right after the amount
    /// ("twelve thousand five hundred dollars" becomes `$12,500`, "3 pounds" becomes `£3`). A symbol with no
    /// amount, on another amount, or for another currency is invented, whatever else the input carries.
    static func hasInventedCurrency(input: String, output: String) -> Bool {
        let outputChars = Array(output)
        guard outputChars.contains(where: isCurrencySymbol) else { return false }
        var allowed = writtenCurrency(in: Array(input))
        let words = input.split(whereSeparator: \.isWhitespace).map { WordTools.trimEdges(String($0)).lowercased() }
        for index in words.indices.dropLast() {
            if let symbol = spokenUnits[words[index + 1]], let amount = amountKey(words[index]) {
                allowed.insert(CurrencyAmount(symbol: symbol, amount: amount))
            }
        }
        var used: [CurrencyAmount] = []
        for (index, character) in outputChars.enumerated() where isCurrencySymbol(character) {
            guard let amount = amountAfter(outputChars, index) ?? amountBefore(outputChars, index) else { return true }
            used.append(CurrencyAmount(symbol: character, amount: amount))
        }
        return used.contains { !allowed.contains($0) }
    }

    /// Symbols the text carries with their amounts, in front of the number or behind it.
    private static func writtenCurrency(in chars: [Character]) -> Set<CurrencyAmount> {
        var found: Set<CurrencyAmount> = []
        for (index, character) in chars.enumerated() where isCurrencySymbol(character) {
            for amount in [amountAfter(chars, index), amountBefore(chars, index)] {
                if let amount { found.insert(CurrencyAmount(symbol: character, amount: amount)) }
            }
        }
        return found
    }

    private static func amountAfter(_ chars: [Character], _ symbol: Int) -> String? {
        var i = symbol + 1
        if i < chars.count, chars[i] == " " { i += 1 }
        var text = ""
        while i < chars.count, chars[i].isASCII, chars[i].isNumber || chars[i] == "," || (chars[i] == "." && text.last?.isNumber == true) {
            text.append(chars[i])
            i += 1
        }
        return amountKey(text)
    }

    private static func amountBefore(_ chars: [Character], _ symbol: Int) -> String? {
        var i = symbol - 1
        if i >= 0, chars[i] == " " { i -= 1 }
        var text = ""
        while i >= 0, chars[i].isASCII, chars[i].isNumber || chars[i] == "," || chars[i] == "." {
            text.insert(chars[i], at: text.startIndex)
            i -= 1
        }
        return amountKey(text)
    }

    /// "12,500." and "12,500" are the same amount; nothing numeric gives nil.
    private static func amountKey(_ amount: String) -> String? {
        let trimmed = amount.trimmingCharacters(in: CharacterSet(charactersIn: ",.")).replacingOccurrences(of: ",", with: "")
        guard trimmed.first?.isNumber == true, trimmed.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return trimmed
    }

    private static func containsNewMeta(inWords: [String], outWords: [String]) -> Bool {
        for phrase in WordLists.metaPhrases {
            let inOutput = outWords.indices.contains { CorrectionMarkers.matches(phrase, in: outWords, at: $0) }
            if inOutput, !inWords.indices.contains(where: { CorrectionMarkers.matches(phrase, in: inWords, at: $0) }) {
                return true
            }
        }
        return false
    }

    // MARK: - Questions

    private static let whFollowers: Set<String> = [
        "is", "are", "was", "were", "do", "does", "did", "can", "could", "would", "will", "should", "about", "many", "much",
    ]

    /// "can you ...", "is the build ...", "what is ...". Skips openers like "hey" and "okay so".
    static func startsAsQuestion(_ words: [String]) -> Bool {
        var start = 0
        while start < min(2, words.count), WordLists.leadingInterjections.contains(words[start]) { start += 1 }
        guard start + 1 < words.count else { return false }
        let first = words[start]
        let second = words[start + 1]
        if WordLists.interrogatives.contains(first) { return whFollowers.contains(second) }
        guard WordLists.questionAuxiliaries.contains(first) else { return false }
        if WordLists.imperativeAuxiliaries.contains(first) { return WordLists.personWords.contains(second) }
        return WordLists.questionSecondWords.contains(second)
    }

    private static func isQuestion(input: String, inWords: [String]) -> Bool {
        if input.contains("?") { return true }
        if inWords.indices.contains(where: { CorrectionMarkers.matches(["question", "mark"], in: inWords, at: $0) }) { return true }
        return startsAsQuestion(inWords)
    }

    private static func questionRules(input: String, inWords: [String], output: String, outWords: [String]) -> FallbackReason? {
        let inputIsQuestion = isQuestion(input: input, inWords: inWords)
        if inputIsQuestion, !output.contains("?") { return .questionLost }
        if !inputIsQuestion, startsAsQuestion(outWords) { return .statementToQuestion }
        return nil
    }
}
