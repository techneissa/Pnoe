import FormatterCore
import FormatterMLXSupport
import Jinja
import XCTest

/// The prompt text a model folder's chat template produces, rendered the way swift-transformers renders it
/// (trim and lstrip blocks, `messages` and `add_generation_prompt` in the context). No model is loaded and no
/// MLX array is made: these check the text the runtime tokenizes.
final class ChatTemplateRenderingTests: XCTestCase {
    /// A trimmed-down Gemma 4 template: system turn first, `<|turn>role` turns, a closed thought channel after the
    /// generation prompt when thinking is off.
    private let gemma4 = """
        {{ bos_token }}
        {%- if messages[0]['role'] == 'system' -%}
        <|turn>system
        {{ messages[0]['content'] | trim }}<turn|>

        {%- set rest = messages[1:] -%}
        {%- else -%}
        {%- set rest = messages -%}
        {%- endif -%}
        {%- for message in rest -%}
        <|turn>{{ 'model' if message['role'] == 'assistant' else message['role'] }}
        {{ message['content'] | trim }}<turn|>

        {%- endfor -%}
        {%- if add_generation_prompt -%}
        <|turn>model
        {% if not enable_thinking %}<|channel>thought
        <channel|>{% endif %}
        {%- endif -%}
        """

    /// A trimmed-down Qwen3 template: ChatML turns, `<think>` mentioned for thinking control.
    private let qwen3 = """
        {%- for message in messages -%}
        <|im_start|>{{ message['role'] }}
        {{ message['content'] }}<|im_end|>
        {% endfor -%}
        {%- if add_generation_prompt -%}
        <|im_start|>assistant
        {% if enable_thinking is defined and enable_thinking is false %}<think>

        </think>

        {% endif %}
        {%- endif -%}
        """

    private func render(_ template: String, _ messages: [ChatMessage], generationPrompt: Bool, thinking: Bool = false) throws -> String {
        let compiled = try Template(template, with: .init(lstripBlocks: true, trimBlocks: true))
        let turns: [Value] = messages.map { .object(["role": .string($0.role.rawValue), "content": .string($0.content)]) }
        return try compiled.render([
            "messages": .array(turns),
            "add_generation_prompt": .boolean(generationPrompt),
            "enable_thinking": .boolean(thinking),
            "bos_token": .string("<bos>"),
        ])
    }

    private let prefix = [ChatMessage(role: .system, content: "Fix punctuation. Keep the words.")]
    private let suffix = [ChatMessage(role: .user, content: "so um we shipped it on tuesday")]

    func testThePrefixIsATextPrefixOfTheWholePrompt() throws {
        for template in [gemma4, qwen3] {
            let head = try render(template, prefix, generationPrompt: false)
            let whole = try render(template, prefix + suffix, generationPrompt: true)
            XCTAssertTrue(whole.hasPrefix(head), "cache boundary moves in: \(whole)")
            XCTAssertGreaterThan(whole.count, head.count)
        }
    }

    func testGemma4TextCarriesTheTurnsAndAClosedThoughtChannel() throws {
        let whole = try render(gemma4, prefix + suffix, generationPrompt: true)
        XCTAssertTrue(whole.hasPrefix("<bos><|turn>system\nFix punctuation. Keep the words.<turn|>"))
        XCTAssertTrue(whole.contains("<|turn>user\nso um we shipped it on tuesday<turn|>"))
        XCTAssertTrue(whole.hasSuffix(MLXChatTemplate.emptyThoughtChannel), whole)
        // A template that already closes the channel gets nothing more.
        XCTAssertNil(MLXChatTemplate.closingThinking(template: gemma4, promptTail: String(whole.suffix(60))))
    }

    func testAThinkingTemplateEndsInAnEmptyThinkBlock() throws {
        let whole = try render(qwen3, prefix + suffix, generationPrompt: true)
        XCTAssertTrue(whole.hasSuffix("<think>\n\n</think>\n\n"), whole)
        XCTAssertNil(MLXChatTemplate.closingThinking(template: qwen3, promptTail: String(whole.suffix(60))))
    }

    func testATemplateThatIgnoresTheSwitchGetsTheBlockAppended() throws {
        // A thinking template that does not read `enable_thinking`: the runtime adds the block itself.
        let stubborn = "{% for m in messages %}<|im_start|>{{ m['role'] }}\n{{ m['content'] }}<|im_end|>\n{% endfor %}{% if add_generation_prompt %}<|im_start|>assistant\n<!-- <think> -->{% endif %}"
        let whole = try render(stubborn, prefix + suffix, generationPrompt: true)
        let closing = try XCTUnwrap(MLXChatTemplate.closingThinking(template: stubborn, promptTail: String(whole.suffix(60))))
        XCTAssertEqual(closing, "<think>\n\n</think>\n\n")
        XCTAssertTrue((whole + closing).hasSuffix("</think>\n\n"))
    }
}
