import Foundation

public struct ProtectedSpan: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case url, email, path, fileName, identifier, version, number, vocabulary
    }

    /// 1-based, the n in `⟦n⟧`.
    public let id: Int
    /// The exact text that is pasted when the marker is restored.
    public let written: String
    public let kind: Kind
}

/// A take with its exact spans swapped for `⟦n⟧` markers.
public struct ProtectedText: Sendable, Equatable {
    /// The text the model sees.
    public let text: String
    /// The same take with every span written out: spoken forms turned into written ones, nothing swapped.
    /// `restore(text)` equals this.
    public let normalized: String
    public let spans: [ProtectedSpan]

    public func marker(for span: ProtectedSpan) -> String { TokenProtector.marker(span.id) }

    /// Puts each span's written text back. Markers with an unknown id are left alone.
    public func restore(_ output: String) -> String {
        var result = output
        for match in TokenProtector.markerMatches(in: output).reversed() {
            guard let span = spans.first(where: { $0.id == match.id }) else { continue }
            result.replaceSubrange(match.range, with: span.written)
        }
        return result
    }
}

public enum TokenProtector {
    public static let open: Character = "⟦"
    public static let close: Character = "⟧"

    public static func marker(_ n: Int) -> String { "\(open)\(n)\(close)" }

    /// Replaces URLs, emails, files, paths, identifiers, versions, numbers and vocabulary terms with markers.
    /// Spoken forms are written out first ("utils slash text dot py" becomes `utils/text.py`), so the model
    /// only ever sees written forms. `vocabulary` terms match case-insensitively and keep their canonical spelling.
    public static func protect(_ text: String, vocabulary: [String] = []) -> ProtectedText {
        // Markers the speaker's text already carries would confuse the placeholder check.
        let clean = text.filter { $0 != open && $0 != close }
        let tokens = Tokenizer.tokenize(clean)
        let found = SpanFinder.find(in: tokens, vocabulary: vocabulary)

        var protectedPieces: [String] = []
        var normalizedPieces: [String] = []
        var spans: [ProtectedSpan] = []
        var index = 0
        var next = 0
        while index < tokens.count {
            if next < found.count, found[next].range.lowerBound == index {
                let span = found[next]
                let id = spans.count + 1
                let first = tokens[span.range.lowerBound]
                let last = tokens[span.range.upperBound - 1]
                spans.append(ProtectedSpan(id: id, written: span.written, kind: span.kind))
                protectedPieces.append(first.lead + marker(id) + span.suffix + last.trail)
                normalizedPieces.append(first.lead + span.written + span.suffix + last.trail)
                index = span.range.upperBound
                next += 1
            } else {
                protectedPieces.append(tokens[index].text)
                normalizedPieces.append(tokens[index].text)
                index += 1
            }
        }
        return ProtectedText(
            text: protectedPieces.joined(separator: " "),
            normalized: normalizedPieces.joined(separator: " "),
            spans: spans
        )
    }

    struct MarkerMatch {
        let id: Int
        let range: Range<String.Index>
    }

    /// Well-formed `⟦n⟧` markers in order.
    static func markerMatches(in text: String) -> [MarkerMatch] {
        text.matches(of: #/⟦(\d+)⟧/#).compactMap { match in
            Int(match.output.1).map { MarkerMatch(id: $0, range: match.range) }
        }
    }
}

/// Step 3 of the pipeline, first half: spoken exact forms written out, nothing swapped.
public enum SpokenNormalizer {
    public static func normalize(_ text: String, vocabulary: [String] = []) -> String {
        TokenProtector.protect(text, vocabulary: vocabulary).normalized
    }
}
