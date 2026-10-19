import XCTest

@testable import FormatterMLXSupport

final class MLXChatTemplateTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-template-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testReadsTheJinjaFileFirst() throws {
        try write("chat_template.jinja", "FROM FILE {{ messages }}")
        try write("tokenizer_config.json", #"{"chat_template": "FROM CONFIG"}"#)
        XCTAssertEqual(MLXChatTemplate.source(inFolder: folder), "FROM FILE {{ messages }}")
    }

    func testReadsTheTemplateStringFromTheTokenizerConfig() throws {
        try write("tokenizer_config.json", #"{"chat_template": "{{ bos_token }}hi"}"#)
        XCTAssertEqual(MLXChatTemplate.source(inFolder: folder), "{{ bos_token }}hi")
    }

    func testReadsTheTemplateJson() throws {
        try write("chat_template.json", #"{"chat_template": "<|turn>user\n{{ x }}"}"#)
        XCTAssertEqual(MLXChatTemplate.source(inFolder: folder), "<|turn>user\n{{ x }}")
    }

    func testAListOfTemplatesUsesTheDefaultOne() throws {
        try write(
            "tokenizer_config.json",
            #"{"chat_template": [{"name": "tool_use", "template": "TOOLS"}, {"name": "default", "template": "PLAIN"}]}"#)
        XCTAssertEqual(MLXChatTemplate.source(inFolder: folder), "PLAIN")
    }

    func testAFolderWithoutATemplateHasNone() throws {
        try write("tokenizer_config.json", #"{"model_max_length": 4096}"#)
        XCTAssertNil(MLXChatTemplate.source(inFolder: folder))
        try write("chat_template.jinja", "")
        XCTAssertNil(MLXChatTemplate.source(inFolder: folder))
    }

    func testAThinkingTemplateGetsTheEmptyThinkBlock() {
        let qwen = "{%- if add_generation_prompt %}<|im_start|>assistant\n{% if enable_thinking is false %}<think>\n\n</think>\n\n{% endif %}{% endif %}"
        XCTAssertTrue(MLXChatTemplate.thinks(qwen))
        XCTAssertEqual(
            MLXChatTemplate.closingThinking(template: qwen, promptTail: "<|im_start|>assistant\n"),
            "<think>\n\n</think>\n\n")
    }

    func testThePromptThatAlreadyEndsInTheBlockIsLeftAlone() {
        let qwen = "... <think> ..."
        XCTAssertNil(
            MLXChatTemplate.closingThinking(template: qwen, promptTail: "<|im_start|>assistant\n<think>\n\n</think>\n\n"))
    }

    func testGemma4GetsAClosedThoughtChannel() {
        let gemma4 = "<|turn>model\n{% if not enable_thinking %}<|channel>thought\n<channel|>{% endif %}"
        XCTAssertEqual(
            MLXChatTemplate.closingThinking(template: gemma4, promptTail: "<|turn>model\n"),
            "<|channel>thought\n<channel|>")
        XCTAssertNil(
            MLXChatTemplate.closingThinking(template: gemma4, promptTail: "<|turn>model\n<|channel>thought\n<channel|>"))
    }

    func testATemplateWithoutThinkingGetsNothing() {
        let gemma = "<|turn>{{ role }}\n{{ content }}<turn|>\n"
        XCTAssertFalse(MLXChatTemplate.thinks(gemma))
        XCTAssertNil(MLXChatTemplate.closingThinking(template: gemma, promptTail: "<|turn>model\n"))
    }

    func testTheSuffixIsWhatFollowsThePrefix() {
        XCTAssertEqual(MLXChatTemplate.suffix(of: [1, 2, 3, 4, 5], afterPrefix: [1, 2, 3]), [4, 5])
    }

    func testARewrittenPrefixHasNoSuffix() {
        XCTAssertNil(MLXChatTemplate.suffix(of: [1, 9, 3, 4], afterPrefix: [1, 2, 3]))
        XCTAssertNil(MLXChatTemplate.suffix(of: [1, 2, 3], afterPrefix: [1, 2, 3]))
        XCTAssertNil(MLXChatTemplate.suffix(of: [1, 2], afterPrefix: []))
    }
}
