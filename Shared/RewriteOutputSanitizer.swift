import FormatterCore
import Foundation

/// The only check on templates that rewrite the text (Checklist, Meeting Notes, Summary, Translation,
/// Email Reply): strips "Here is…" preambles, code fences, think blocks and wrapping quotes. There is
/// no word-diff guard here, because these templates are meant to change the words. A reply the sanitizer
/// rejects (empty, or wrapped in JSON it cannot unwrap) is never pasted: the transcript is.
enum RewriteOutputSanitizer {
    static func sanitize(_ output: String, input: String) -> String {
        switch OutputSanitizer.sanitize(output, input: input) {
        case .success(let text): text
        case .failure: input
        }
    }
}
