import Foundation

/// The text-level rules of the MLX engine that need no MLX: which chat template a model folder carries, when the
/// reply must start after an empty think block, and where the cached prompt prefix ends. They live here so
/// `swift test` on this package covers them without building MLX; `MLXRuntime` applies them to real tokens.
public enum MLXChatTemplate {
    /// What a model that thinks by default needs after the generation prompt so it answers at once: an empty
    /// think block. A Qwen3-style template mentions `<think>`; without this the model starts thinking and runs
    /// into the token cap, and every take falls back. The llama engine does the same.
    public static let emptyThinkingBlock = "<think>\n\n</think>\n\n"

    /// Stop texts looked up in the vocabulary as insurance for a model whose `generation_config.json` does not
    /// list its turn-end token (the llama engine has the same list).
    public static let stopTexts = ["<turn|>", "<end_of_turn>", "<|im_end|>", "<|eot_id|>"]

    /// The Jinja chat template a model folder carries, or nil. Newer conversions keep it in
    /// `chat_template.jinja` (or `chat_template.json`), older ones in `tokenizer_config.json`, as one string or
    /// as a list of named templates of which `default` is used.
    public static func source(inFolder folder: URL) -> String? {
        let fileManager = FileManager.default
        let jinja = folder.appendingPathComponent("chat_template.jinja")
        if let text = try? String(contentsOf: jinja, encoding: .utf8), !text.isEmpty { return text }

        for name in ["chat_template.json", "tokenizer_config.json"] {
            let url = folder.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path),
                let data = try? Data(contentsOf: url),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let value = object["chat_template"]
            else { continue }
            if let text = value as? String, !text.isEmpty { return text }
            if let list = value as? [[String: Any]] {
                let named = Dictionary(
                    list.compactMap { item -> (String, String)? in
                        guard let name = item["name"] as? String, let template = item["template"] as? String else { return nil }
                        return (name, template)
                    },
                    uniquingKeysWith: { first, _ in first })
                if let text = named["default"] ?? named.values.first { return text }
            }
        }
        return nil
    }

    /// Gemma 4's equivalent: an empty thought channel, closed, after the generation prompt.
    public static let emptyThoughtChannel = "<|channel>thought\n<channel|>"

    /// Whether the template makes the model think before it answers (it mentions a think block or Gemma 4's
    /// thought channel).
    public static func thinks(_ template: String) -> Bool {
        template.contains("<think>") || template.contains("<|channel>")
    }

    /// The text to add after the generation prompt: the empty think block (or Gemma 4's closed thought channel)
    /// when `template` thinks and the prompt (its last tokens, decoded) does not already end in it. Nil when
    /// nothing is to be added. Templates that honour `enable_thinking = false` already emit it themselves.
    public static func closingThinking(template: String, promptTail: String) -> String? {
        let block = template.contains("<|channel>") ? emptyThoughtChannel : emptyThinkingBlock
        guard thinks(template), !promptTail.hasSuffix(block) else { return nil }
        return block
    }

    /// Splits a rendered conversation at the cache boundary. `prefix` is the token ids of the fixed turns alone,
    /// `whole` those of the whole conversation with its generation prompt. The suffix is what the cache does not
    /// hold; nil when `whole` does not start with `prefix` (the template rewrote the earlier turns), in which
    /// case the caller decodes the whole prompt for the request.
    public static func suffix(of whole: [Int], afterPrefix prefix: [Int]) -> [Int]? {
        guard !prefix.isEmpty, whole.count > prefix.count, whole.starts(with: prefix) else { return nil }
        return Array(whole.dropFirst(prefix.count))
    }
}
