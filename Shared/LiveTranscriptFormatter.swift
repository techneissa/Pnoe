import AppKit

/// Keeps the newest words of a running transcript so they fit in a fixed number of lines.
enum LiveTranscriptFormatter {
    /// Longest stretch of text that is ever measured; older text cannot fit in two lines anyway.
    private static let measuredCharacterLimit = 480

    static let ellipsis = "…"

    /// Returns the longest suffix of `text`, starting at a word boundary, that fits in
    /// `maxLines` lines of `width` points at `fontSize`. A cut-off start is marked with an
    /// ellipsis. The ellipsis is part of what is measured, so the result never needs a third line.
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

        var source = Substring(trimmed)
        var wasCut = false
        if source.count > measuredCharacterLimit {
            source = source.suffix(measuredCharacterLimit)
            wasCut = true
        }
        let words = source.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // A suffix that begins mid-word is not shown: drop the first word of a measured cut.
        let candidates = wasCut ? Array(words.dropFirst()) : words
        guard !candidates.isEmpty else { return trimmed }

        // Binary search the first word index whose suffix still fits; fits() is monotonic.
        var low = 0
        var high = candidates.count - 1
        while low < high {
            let mid = (low + high) / 2
            if fits(prefixed(Array(candidates[mid...]), cut: mid > 0 || wasCut)) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        // `low` is the first fitting start, or the last word when nothing fits.
        let result = prefixed(Array(candidates[low...]), cut: low > 0 || wasCut)
        return result
    }

    private static func prefixed(_ words: [String], cut: Bool) -> String {
        let joined = words.joined(separator: " ")
        return cut ? ellipsis + joined : joined
    }
}
