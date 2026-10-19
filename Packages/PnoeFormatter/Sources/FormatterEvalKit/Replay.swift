import FormatterCore
import Foundation

/// Round 1 outputs, one entry per distinct (case, output). `runs` lists the model and prompt runs that produced it.
public struct ReplayEntry: Codable, Sendable, Equatable {
    public enum Label: String, Codable, Sendable {
        /// Facts kept and similar to the target.
        case good
        /// An unfaithful output; `category` says how.
        case bad
        /// Neither (a format-only miss).
        case other
    }

    /// The round 1 case id, without the `r1-` prefix.
    public var `case`: String
    public var output: String
    public var label: Label
    public var category: String?
    public var runs: [String]

    /// Round 1 ran each model and prompt once, so one entry stands for `runs.count` stored outputs.
    public var weight: Int { runs.count }
}

public struct ReplayFile: Codable, Sendable {
    public var runs: Int
    public var entries: [ReplayEntry]

    public static func load(from url: URL) throws -> ReplayFile {
        try JSONDecoder().decode(ReplayFile.self, from: Data(contentsOf: url))
    }
}

/// Serves one stored output. It is a `FormatterRuntime` so the stored text goes through the same pipeline as
/// a live model: sanitizer, placeholder check, word-diff guard.
public struct ReplayRuntime: FormatterRuntime {
    public let id: FormatterRuntimeID = .llama
    public var output: String
    public var stopReason: StopReason

    public init(output: String, stopReason: StopReason = .eos) {
        self.output = output
        self.stopReason = stopReason
    }

    public func prepare(_ spec: RuntimeModelSpec, prefix: PromptPrefix) async throws {}

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        GenerationResult(text: output, stopReason: stopReason)
    }

    public func cancel(_ requestID: UUID) async {}
    public func unload() async {}
}

/// Round 1 stored what the model wrote when it saw the written-out take. The pipeline now shows the model
/// `⟦n⟧` markers for exact spans, so a stored output is rewritten the way a marker-aware model would answer:
/// each protected span found in the output becomes its marker. A span the stored output changed or lost
/// has no match, so its marker is missing and the placeholder check fires, which is what the live pipeline
/// does to a model that rewrites a path it was given as a marker.
public enum Markerizer {
    public static func markerize(_ output: String, protected: ProtectedText) -> String {
        var claimed: [(range: Range<String.Index>, id: Int)] = []
        var searchFrom = output.startIndex
        for span in protected.spans where !span.written.isEmpty {
            // Prefer the next match after the previous span, so repeated text pairs up in order.
            var found: Range<String.Index>?
            for form in surfaceForms(of: span) {
                found = firstMatch(of: form, in: output, from: searchFrom, avoiding: claimed)
                    ?? firstMatch(of: form, in: output, from: output.startIndex, avoiding: claimed)
                if found != nil { break }
            }
            if let range = found {
                claimed.append((range, span.id))
                searchFrom = range.upperBound
            }
        }
        var result = output
        for item in claimed.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(item.range, with: TokenProtector.marker(item.id))
        }
        return result
    }

    /// How a stored output may write a span: as the pipeline writes it, and for a number also in words
    /// ("10 minutes" as "ten minutes", "10%" as "10 percent"). A model shown the marker keeps the marker in
    /// all of these, so they all map to it.
    static func surfaceForms(of span: ProtectedSpan) -> [String] {
        var forms = [span.written]
        guard span.kind == .number else { return forms }
        let text = span.written
        let digits = text.prefix { $0.isNumber || $0 == "," }
        guard !digits.isEmpty, let value = Int(digits.replacingOccurrences(of: ",", with: "")), value < 1_000_000 else { return forms }
        let rest = String(text.dropFirst(digits.count))
        let words = EnglishNumber.spell(value)
        let tail = rest.replacingOccurrences(of: "%", with: " percent")
        forms.append(words + (rest.hasPrefix("%") ? tail : rest))
        forms.append(words.replacingOccurrences(of: " ", with: "-") + (rest.hasPrefix("%") ? tail : rest))
        if rest.hasPrefix("%") { forms.append(String(digits) + tail) }
        return forms
    }

    private static func firstMatch(
        of needle: String, in text: String, from start: String.Index, avoiding claimed: [(range: Range<String.Index>, id: Int)]
    ) -> Range<String.Index>? {
        var from = start
        while from < text.endIndex, let range = text.range(of: needle, options: .caseInsensitive, range: from..<text.endIndex) {
            if !claimed.contains(where: { $0.range.overlaps(range) }), boundaryOK(text, range, needle) { return range }
            from = text.index(after: range.lowerBound)
        }
        return nil
    }

    /// A span that starts or ends with a letter or digit must not sit inside a longer word or number.
    private static func boundaryOK(_ text: String, _ range: Range<String.Index>, _ needle: String) -> Bool {
        if let first = needle.first, first.isLetter || first.isNumber, range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            if before.isLetter || before.isNumber || before == "_" { return false }
        }
        if let last = needle.last, last.isLetter || last.isNumber, range.upperBound < text.endIndex {
            let after = text[range.upperBound]
            if after.isLetter || after.isNumber || after == "_" { return false }
        }
        return true
    }
}

/// Cardinal numbers in English words, for matching how a stored output wrote a number.
enum EnglishNumber {
    private static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
                               "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    static func spell(_ n: Int) -> String {
        switch n {
        case ..<20: ones[max(0, n)]
        case ..<100: tens[n / 10] + (n % 10 == 0 ? "" : " " + ones[n % 10])
        case ..<1000: ones[n / 100] + " hundred" + (n % 100 == 0 ? "" : " " + spell(n % 100))
        default: spell(n / 1000) + " thousand" + (n % 1000 == 0 ? "" : " " + spell(n % 1000))
        }
    }
}

/// Round 1 wrote its outputs from the raw take, but the live pipeline cleans the take first and the model
/// answers the cleaned text. The cleanup that matters for judging a stored output is the one that removes
/// words from the front (the chat openers "so" and "okay"): a model never sees them, so it never writes them
/// back. The replay drops the same opener words from the stored output, then marks the protected spans.
public enum ReplayAlignment {
    private static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "hmm", "hm", "mm", "mmm"]

    static func word(_ token: Substring) -> String {
        token.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" }
    }

    /// The opener words the cleanup took off the front of `raw`.
    static func droppedOpeners(raw: String, context: FormatterContext) -> [String] {
        let rawWords = raw.split(whereSeparator: \.isWhitespace).map(word).filter { !$0.isEmpty && !fillers.contains($0) }
        let cleanedWords = FillerCleaner.clean(raw, context: context).split(whereSeparator: \.isWhitespace).map(word).filter { !$0.isEmpty }
        guard let first = cleanedWords.first, let start = rawWords.firstIndex(of: first), start > 0 else { return [] }
        return Array(rawWords[..<start])
    }

    /// `output` without the leading words that the cleanup removed from the input.
    public static func dropCleanedOpeners(from output: String, raw: String, context: FormatterContext) -> String {
        let dropped = droppedOpeners(raw: raw, context: context)
        guard !dropped.isEmpty else { return output }
        var rest = Substring(output)
        var matched = 0
        while matched < dropped.count {
            let trimmed = rest.drop(while: \.isWhitespace)
            let token = trimmed.prefix(while: { !$0.isWhitespace })
            guard !token.isEmpty, word(token) == dropped[matched] else { break }
            rest = trimmed.dropFirst(token.count)
            matched += 1
        }
        guard matched > 0 else { return output }
        let body = rest.drop(while: \.isWhitespace)
        guard let first = body.first else { return "" }
        return first.uppercased() + body.dropFirst()
    }

    /// What a marker-aware model that saw the cleaned take would have answered, from a stored or ideal text.
    public static func modelAnswer(forStored text: String, testCase: EvalCase) -> String {
        let aligned = dropCleanedOpeners(from: text, raw: testCase.raw, context: testCase.context)
        let protected = TokenProtector.protect(FillerCleaner.clean(testCase.raw, context: testCase.context))
        return Markerizer.markerize(aligned, protected: protected)
    }
}
