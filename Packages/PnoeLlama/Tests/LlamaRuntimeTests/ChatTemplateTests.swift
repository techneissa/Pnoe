import FormatterCore
import Testing
@testable import LlamaRuntime

@Suite("Gemma 4 chat template")
struct ChatTemplateTests {
    static let prefix = [
        ChatMessage(role: .system, content: "  Clean the text.  \n"),
        ChatMessage(role: .user, content: "shot in"),
        ChatMessage(role: .assistant, content: "shot out"),
    ]
    static let suffix = [ChatMessage(role: .user, content: "hello there ")]

    @Test("the turns follow the template shipped with Gemma 4: system turn, user and model turns, thought channel closed")
    func rendersTurns() {
        let text = ChatTemplate.renderGemma4(Self.prefix + Self.suffix, addGenerationPrompt: true)
        #expect(
            text == "<bos><|turn>system\nClean the text.<turn|>\n"
                + "<|turn>user\nshot in<turn|>\n<|turn>model\nshot out<turn|>\n"
                + "<|turn>user\nhello there<turn|>\n<|turn>model\n<|channel>thought\n<channel|>")
    }

    @Test("a conversation without a system turn starts with the first user turn")
    func noSystem() {
        let text = ChatTemplate.renderGemma4([ChatMessage(role: .user, content: "hi")], addGenerationPrompt: false)
        #expect(text == "<bos><|turn>user\nhi<turn|>\n")
    }

    @Test("thinking an earlier model turn did is dropped from the history")
    func stripsThinking() {
        #expect(ChatTemplate.stripThinking("<|channel>thought\nhmm<channel|> Answer. ") == "Answer.")
        #expect(ChatTemplate.stripThinking("plain") == "plain")
    }

    @Test("the prefix text is a text prefix of every prompt, so the cache boundary falls between turns")
    func splitsAtTheCacheBoundary() throws {
        let split = try #require(
            SplitPrompt.make(prefix: Self.prefix, suffix: Self.suffix) {
                ChatTemplate.renderGemma4($0, addGenerationPrompt: $1)
            })
        #expect(split.prefix.hasSuffix("<|turn>model\nshot out<turn|>\n"))
        #expect(split.suffix == "<|turn>user\nhello there<turn|>\n<|turn>model\n<|channel>thought\n<channel|>")
        let other = try #require(
            SplitPrompt.make(prefix: Self.prefix, suffix: [ChatMessage(role: .user, content: "another take")]) {
                ChatTemplate.renderGemma4($0, addGenerationPrompt: $1)
            })
        #expect(other.prefix == split.prefix)
    }

    @Test("a template that rewrites earlier turns gives no split")
    func noSplit() {
        let split = SplitPrompt.make(prefix: Self.prefix, suffix: Self.suffix) { messages, addAssistant in
            addAssistant ? "rewritten" : "head"
        }
        #expect(split == nil)
    }

    @Test("Gemma 4's template string is recognised by its turn marker, older Gemma by llama.cpp's own list")
    func detection() {
        #expect(ChatTemplate.detect(templateString: "{{ bos_token }}<|turn>system") == .gemma4)
        #expect(ChatTemplate.detect(templateString: "<start_of_turn>user") == .native("<start_of_turn>user"))
        #expect(ChatTemplate.detect(templateString: "") == nil)
        #expect(ChatTemplate.detect(templateString: nil) == nil)
        #expect(ChatTemplate.gemma4.rendersBeginningOfSequence)
        #expect(!ChatTemplate.native("x").rendersBeginningOfSequence)
    }

    @Test("a template that supports thinking gets the empty think block after the generation prompt, once")
    func closesThinking() {
        let qwen = "{%- if enable_thinking is defined %}<think>{%- endif %}<|im_start|>"
        let prompt = "<|im_start|>user\nhi<|im_end|>\n<|im_start|>assistant\n"
        let closed = ChatTemplate.closingThinking(prompt, template: qwen, addGenerationPrompt: true)
        #expect(closed == prompt + "<think>\n\n</think>\n\n")
        #expect(ChatTemplate.closingThinking(closed, template: qwen, addGenerationPrompt: true) == closed)
        // No generation prompt (the cached prefix), or a template without thinking: unchanged.
        #expect(ChatTemplate.closingThinking(prompt, template: qwen, addGenerationPrompt: false) == prompt)
        #expect(ChatTemplate.closingThinking(prompt, template: "<|im_start|>", addGenerationPrompt: true) == prompt)
    }

    @Test("a template that already opened the think block only gets the rest of it, and a closed one nothing")
    func finishesAnOpenThinkBlock() {
        let template = "<|Assistant|><think>\n"
        let opened = "<|User|>hi<|Assistant|><think>\n"
        #expect(ChatTemplate.closingThinking(opened, template: template, addGenerationPrompt: true) == opened + "\n</think>\n\n")
        let closed = opened + "\n</think>\n\n"
        #expect(ChatTemplate.closingThinking(closed, template: template, addGenerationPrompt: true) == closed)
    }

    @Test("the prefix is still a text prefix of the whole prompt once the think block is added")
    func splitKeepsWorkingWithThinking() throws {
        let qwen = "<think><|im_start|>"
        let render: ([ChatMessage], Bool) -> String = { messages, addAssistant in
            let body = messages.map { "<|im_start|>\($0.role.rawValue)\n\($0.content)<|im_end|>\n" }.joined()
            return ChatTemplate.closingThinking(body + (addAssistant ? "<|im_start|>assistant\n" : ""), template: qwen, addGenerationPrompt: addAssistant)
        }
        let split = try #require(SplitPrompt.make(prefix: Self.prefix, suffix: Self.suffix, render: render))
        #expect(split.suffix.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n"))
    }
}
