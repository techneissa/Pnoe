import AppKit

/// Keeps the newest words of a running transcript so they fit in a fixed number of lines.
enum LiveTranscriptFormatter {
    /// Longest stretch of text that is ever measured; older text cannot fit in two lines anyway.
    private static let measuredCharacterLimit = 480

    /// A cut that lands inside a word is moved forward to the next space when one is this close.
    /// Text without spaces (Chinese, Japanese, Thai) has none, and is cut between characters.
    private static let wordSnapDistance = 24

    static let ellipsis = "…"

    /// Returns the longest suffix of `text` that fits in `maxLines` lines of `width` points at
    /// `fontSize`. In spaced text the suffix starts at a word boundary; in text without spaces it
    /// starts between characters. A cut-off start is marked with an ellipsis. The ellipsis is part
    /// of what is measured, so the result never needs a third line.
    static func tail(_ text: String, fontSize: CGFloat, width: CGFloat, maxLines: Int = 2) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, width > 0, maxLines > 0 else { return trimmed }

        let font = NSFont.systemFont(ofSize: fontSize)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let allowedHeight = lineHeight * CGFloat(maxLines) + 0.5

        func fits(_ candidate: String) -> Bool {
            let rect = (candidate as NSString).boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            )
            return ceil(rect.height) <= allowedHeight
        }

        let all = Array(trimmed)
        let wasCut = all.count > measuredCharacterLimit
        let chars = wasCut ? Array(all.suffix(measuredCharacterLimit)) : all

        func candidate(from start: Int) -> String {
            let body = String(chars[start...])
            return start > 0 || wasCut ? ellipsis + body : body
        }

        // Binary search the first character index whose suffix still fits; fits() is monotonic.
        var low = 0
        var high = chars.count - 1
        while low < high {
            let mid = (low + high) / 2
            if fits(candidate(from: mid)) {
                high = mid
            } else {
                low = mid + 1
            }
        }

        var start = low
        let cutsMidWord = (start > 0 || wasCut) && (start == 0 || !chars[start - 1].isWhitespace)
        if cutsMidWord || (start < chars.count && chars[start].isWhitespace) {
            let limit = min(chars.count, start + wordSnapDistance)
            if let space = (start..<limit).first(where: { chars[$0].isWhitespace }) {
                var next = space
                while next < chars.count, chars[next].isWhitespace { next += 1 }
                if next < chars.count { start = next }
            }
        }
        return candidate(from: start)
    }
}
