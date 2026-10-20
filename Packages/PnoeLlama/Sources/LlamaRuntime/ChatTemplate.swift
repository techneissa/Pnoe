import FormatterCore
import Foundation

/// Turns chat messages into the text a model was trained on. llama.cpp's own `llama_chat_apply_template`
/// has no Jinja engine and knows a fixed list of formats, and it does not know Gemma 4's, so Gemma 4's turn
/// format is written out here from the template that ships in its GGUF (`models/templates/google-gemma-4-*.jinja`
/// in llama.cpp). Any other model uses llama.cpp's own list through `LlamaRuntime`.
enum ChatTemplate: Equatable, Sendable {
    /// `<|turn>role\n…<turn|>\n`, with a system turn and the empty thinking channel after the generation prompt.
    case gemma4
    /// llama.cpp's `llama_chat_apply_template` with the template string from the GGUF.
    case native(String)

    /// Picks the format from the template string stored in the GGUF (`tokenizer.chat_template`). Gemma 4's
    /// carries `<|turn>`; Gemma 2 and 3 carry `<start_of_turn>`, which llama.cpp already knows.
    static func detect(templateString: String?) -> ChatTemplate? {
        guard let templateString, !templateString.isEmpty else { return nil }
        if templateString.contains("<|turn>") { return .gemma4 }
        return .native(templateString)
    }

    /// True when the text starts with the beginning-of-sequence token itself, so the tokenizer must not add
    /// a second one.
    var rendersBeginningOfSequence: Bool {
        switch self {
        case .gemma4: true
        case .native: false
        }
    }

    /// What a model that thinks by default needs after the generation prompt so it answers at once: an empty
    /// think block. A Qwen3-style template mentions `<think>`; without this the model starts thinking and runs
    /// into the token cap, and every take falls back.
    static let emptyThinkingBlock = "<think>\n\n</think>\n\n"

    /// `rendered` (llama.cpp's output for a template it knows) with the rest of an empty think block appended when
    /// the template supports thinking and the text ends in the generation prompt: the whole block, or only
    /// `\n</think>\n\n` when the template already opened it (`<think>\n`); nothing when it is closed already.
    static func closingThinking(_ rendered: String, template: String, addGenerationPrompt: Bool) -> String {
        guard addGenerationPrompt, template.contains("<think>"), !rendered.hasSuffix(emptyThinkingBlock) else {
            return rendered
        }
        let opened = "<think>\n"
        if rendered.hasSuffix(opened) { return rendered + String(emptyThinkingBlock.dropFirst(opened.count)) }
        return rendered + emptyThinkingBlock
    }

    /// The Gemma 4 text for `messages`. `bos` is the vocabulary's beginning-of-sequence text (`<bos>`).
    static func renderGemma4(_ messages: [ChatMessage], addGenerationPrompt: Bool, bos: String = "<bos>") -> String {
        var output = bos
        var rest = messages[...]
        if let first = messages.first, first.role == .system {
            output += "<|turn>system\n" + first.content.trimmingCharacters(in: .whitespacesAndNewlines) + "<turn|>\n"
            rest = messages.dropFirst()
        }
        for message in rest {
            switch message.role {
            case .user, .system:
                output += "<|turn>\(message.role.rawValue)\n"
                output += message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            case .assistant:
                output += "<|turn>model\n"
                output += stripThinking(message.content)
            }
            output += "<turn|>\n"
        }
        if addGenerationPrompt {
            // Thinking is off: the template closes an empty thought channel so the model answers at once.
            output += "<|turn>model\n<|channel>thought\n<channel|>"
        }
        return output
    }

    /// Removes `<|channel>…<channel|>` spans the model wrote while thinking, as the template does for earlier turns.
    static func stripThinking(_ text: String) -> String {
        var result = ""
        for part in text.components(separatedBy: "<channel|>") {
            if let open = part.range(of: "<|channel>") {
                result += part[..<open.lowerBound]
            } else {
                result += part
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The prompt split at the cache boundary: everything up to the end of the prefix turns, and the rest.
struct SplitPrompt: Equatable, Sendable {
    var prefix: String
    var suffix: String

    /// Renders the prefix alone and the whole conversation with the generation prompt, and splits the second
    /// at the length of the first. Nil when the prefix is not a text prefix of the whole (a template that
    /// rewrites earlier turns), in which case the caller decodes the whole prompt for the request.
    static func make(prefix: [ChatMessage], suffix: [ChatMessage], render: ([ChatMessage], Bool) throws -> String) rethrows -> SplitPrompt? {
        let head = try render(prefix, false)
        let whole = try render(prefix + suffix, true)
        guard whole.hasPrefix(head) else { return nil }
        return SplitPrompt(prefix: head, suffix: String(whole.dropFirst(head.count)))
    }
}
