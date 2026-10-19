import Foundation

/// Step 7: every `⟦n⟧` the model was given comes back exactly once, in order, with no unknown ids and no
/// stray brackets. One exception: a marker inside words the speaker corrected may be dropped with them.
public enum PlaceholderCheck {
    public static func validate(_ output: String, protected: ProtectedText) -> FallbackReason? {
        let matches = TokenProtector.markerMatches(in: output)

        // Stray brackets: any ⟦ or ⟧ that is not part of a well-formed marker.
        var stripped = output
        for match in matches.reversed() { stripped.removeSubrange(match.range) }
        if stripped.contains(TokenProtector.open) || stripped.contains(TokenProtector.close) { return .placeholderUnknown }

        let known = Set(protected.spans.map(\.id))
        if matches.contains(where: { !known.contains($0.id) }) { return .placeholderUnknown }

        var counts: [Int: Int] = [:]
        for match in matches { counts[match.id, default: 0] += 1 }
        if counts.values.contains(where: { $0 > 1 }) { return .placeholderDup }

        let droppable = droppableIDs(protected)
        for id in known where counts[id] == nil && !droppable.contains(id) { return .placeholderLost }

        let ids = matches.map(\.id)
        if ids != ids.sorted() { return .placeholderOrder }
        return nil
    }

    /// Markers the speaker may have corrected away: up to 4 words before a correction phrase, and only when
    /// a marker of the same kind follows the phrase within 3 words ("8080 no wait 9090"). A phrase with no
    /// replacement after it never excuses a lost marker.
    static func droppableIDs(_ protected: ProtectedText) -> Set<Int> {
        let words = protected.text.split(whereSeparator: \.isWhitespace).map { WordTools.trimEdges(String($0)).lowercased() }
        var kinds: [Int: ProtectedSpan.Kind] = [:]
        for span in protected.spans { kinds[span.id] = span.kind }
        func ids(in range: Range<Int>) -> [Int] {
            range.flatMap { TokenProtector.markerMatches(in: words[$0]).map(\.id) }
        }
        var droppable: Set<Int> = []
        for match in CorrectionMarkers.matches(in: words) {
            let after = match.phrase.upperBound..<min(words.count, match.phrase.upperBound + 3)
            let replacementKinds = Set(ids(in: after).compactMap { kinds[$0] })
            for id in ids(in: match.window) {
                if let kind = kinds[id], replacementKinds.contains(kind) { droppable.insert(id) }
            }
        }
        return droppable
    }
}

enum CorrectionMarkers {
    struct Match {
        /// The phrase itself.
        let phrase: Range<Int>
        /// The up to 4 words before it.
        let window: Range<Int>
    }

    static func matches(in words: [String]) -> [Match] {
        var result: [Match] = []
        var i = 0
        while i < words.count {
            if let phrase = WordLists.correctionPhrases.first(where: { matches($0, in: words, at: i) }) {
                result.append(Match(phrase: i..<(i + phrase.count), window: max(0, i - 4)..<i))
                i += phrase.count
            } else {
                i += 1
            }
        }
        return result
    }

    /// Indices of the phrase words themselves, and of the up to 4 words before each phrase.
    static func regions(in words: [String]) -> (markers: Set<Int>, window: Set<Int>) {
        var markers: Set<Int> = []
        var window: Set<Int> = []
        for match in matches(in: words) {
            markers.formUnion(match.phrase)
            window.formUnion(match.window)
        }
        window.subtract(markers)
        return (markers, window)
    }

    static func matches(_ phrase: [String], in words: [String], at i: Int) -> Bool {
        guard i + phrase.count <= words.count else { return false }
        return zip(phrase, words[i...]).allSatisfy { $0 == $1 }
    }
}

enum WordTools {
    /// Strips punctuation from both ends but keeps marker brackets.
    static func trimEdges(_ token: String) -> String {
        func keep(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "⟦" || c == "⟧" }
        guard let start = token.firstIndex(where: keep), let end = token.lastIndex(where: keep) else { return "" }
        return String(token[start...end])
    }
}
