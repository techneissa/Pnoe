import Foundation

/// A word-level diff for showing what a check refused: the words of `new` in order, each marked as kept,
/// added (not in `old`), or the words of `old` that went missing, in place. Words match ignoring case and
/// the punctuation around them.
enum WordDiff {
    enum Kind: Equatable {
        case kept
        /// In the new text only.
        case added
        /// In the old text only.
        case missing
    }

    struct Segment: Equatable {
        let word: String
        let kind: Kind
    }

    static func segments(from old: String, to new: String) -> [Segment] {
        let oldWords = old.split(whereSeparator: \.isWhitespace).map(String.init)
        let newWords = new.split(whereSeparator: \.isWhitespace).map(String.init)
        let oldKeys = oldWords.map(key)
        let newKeys = newWords.map(key)

        // Longest common subsequence over the keys.
        var table = Array(repeating: Array(repeating: 0, count: newKeys.count + 1), count: oldKeys.count + 1)
        for i in stride(from: oldKeys.count - 1, through: 0, by: -1) {
            for j in stride(from: newKeys.count - 1, through: 0, by: -1) {
                table[i][j] =
                    oldKeys[i] == newKeys[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var result: [Segment] = []
        var i = 0
        var j = 0
        while i < oldKeys.count || j < newKeys.count {
            if i < oldKeys.count, j < newKeys.count, oldKeys[i] == newKeys[j] {
                result.append(Segment(word: newWords[j], kind: .kept))
                i += 1
                j += 1
            } else if j < newKeys.count, i == oldKeys.count || table[i][j + 1] >= table[i + 1][j] {
                result.append(Segment(word: newWords[j], kind: .added))
                j += 1
            } else {
                result.append(Segment(word: oldWords[i], kind: .missing))
                i += 1
            }
        }
        return result
    }

    /// True when anything differs.
    static func hasChanges(_ segments: [Segment]) -> Bool {
        segments.contains { $0.kind != .kept }
    }

    private static func key(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }
}
