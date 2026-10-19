import Foundation

/// Step 1 of the guard pipeline: plain-code cleanup before the model sees the take.
/// The app's output filter already drops uh/um and the user's list; this repeats the common ones so the
/// package works on its own, then adds repeats, comma-set "you know" and "like", and chat openers.
/// Self-corrections are left to the model.
public enum FillerCleaner {
    public static func clean(_ text: String, context: FormatterContext) -> String {
        var tokens = Tokenizer.tokenize(text)
        dropFillers(&tokens)
        dropSetOffPhrases(&tokens)
        collapseRepeats(&tokens)
        if context == .chat { dropChatOpeners(&tokens) }
        return Tokenizer.render(tokens)
    }

    private static let sentenceEnd: Set<Character> = [".", "?", "!"]

    private static func dropFillers(_ tokens: inout [Token]) {
        var out: [Token] = []
        for token in tokens {
            guard WordLists.fillers.contains(token.lower) else {
                out.append(token)
                continue
            }
            // Keep a sentence end the filler carried.
            if let end = token.trail.first(where: { sentenceEnd.contains($0) }), var last = out.last, last.trail.isEmpty {
                last.trail = String(end)
                out[out.count - 1] = last
            }
        }
        tokens = out
    }

    /// ", you know," and ", like," go; bare "you know" and "like" stay (they are often real words).
    private static func dropSetOffPhrases(_ tokens: inout [Token]) {
        var i = 0
        while i < tokens.count {
            let atStart = i == 0 || tokens[i - 1].trail.hasSuffix(",")
            if atStart, tokens[i].lower == "like", tokens[i].trail.hasPrefix(","), tokens[i].lead.isEmpty, i + 1 < tokens.count || i > 0 {
                tokens.remove(at: i)
                continue
            }
            if atStart, tokens[i].lower == "you", tokens[i].trail.isEmpty, i + 1 < tokens.count, tokens[i + 1].lower == "know" {
                let know = tokens[i + 1]
                let setOff = know.trail.hasPrefix(",") || (i + 2 == tokens.count)
                if setOff {
                    if i > 0, let end = know.trail.first(where: { sentenceEnd.contains($0) }) {
                        tokens[i - 1].trail = String(end)
                    }
                    tokens.removeSubrange(i...(i + 1))
                    continue
                }
            }
            i += 1
        }
    }

    /// "the the" and "I I" become one word; only words of 4 letters or fewer, and only with no punctuation between.
    private static func collapseRepeats(_ tokens: inout [Token]) {
        var i = 0
        while i + 1 < tokens.count {
            let a = tokens[i]
            let b = tokens[i + 1]
            if a.trail.isEmpty, a.lead.isEmpty, b.lead.isEmpty, a.core.count <= 4, a.core.allSatisfy(\.isLetter),
               a.lower == b.lower {
                tokens[i].trail = b.trail
                tokens.remove(at: i + 1)
                continue
            }
            i += 1
        }
    }

    private static func dropChatOpeners(_ tokens: inout [Token]) {
        while tokens.count > 4, ["so", "okay", "ok"].contains(tokens[0].lower) {
            tokens.removeFirst()
        }
    }
}
