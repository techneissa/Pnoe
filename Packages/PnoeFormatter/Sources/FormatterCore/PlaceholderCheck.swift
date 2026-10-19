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

    /// Markers the speaker may have corrected away: up to 4 words before a correction phrase.
    static func droppableIDs(_ protected: ProtectedText) -> Set<Int> {
        let words = protected.text.split(whereSeparator: \.isWhitespace).map { WordTools.trimEdges(String($0)).lowercased() }
        let regions = CorrectionMarkers.regions(in: words)
        var ids: Set<Int> = []
        for index in regions.window {
            let word = words[index]
            for match in TokenProtector.markerMatches(in: word) { ids.insert(match.id) }
        }
        return ids
    }
}

enum CorrectionMarkers {
    /// Indices of the marker words themselves, and of the up to 4 words before each marker.
    static func regions(in words: [String]) -> (markers: Set<Int>, window: Set<Int>) {
        var markers: Set<Int> = []
        var window: Set<Int> = []
        var i = 0
        while i < words.count {
            if let phrase = WordLists.correctionPhrases.first(where: { matches($0, in: words, at: i) }) {
                for k in i..<(i + phrase.count) { markers.insert(k) }
                for k in max(0, i - 4)..<i { window.insert(k) }
                i += phrase.count
            } else {
                i += 1
            }
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
