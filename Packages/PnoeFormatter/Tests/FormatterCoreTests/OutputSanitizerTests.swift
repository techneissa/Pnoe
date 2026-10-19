import Testing
@testable import FormatterCore

@Suite("OutputSanitizer")
struct OutputSanitizerTests {
    struct Case: Sendable {
        let name: String
        let output: String
        let input: String
        let expected: String
    }

    static let accepts: [Case] = [
        Case(name: "plain", output: "Open ⟦1⟧ now.", input: "open ⟦1⟧ now", expected: "Open ⟦1⟧ now."),
        Case(name: "think block", output: "<think>let me see</think>\nHello there.", input: "hello there", expected: "Hello there."),
        Case(name: "think block multiline", output: "<think>\nreasoning\nmore\n</think>Hello there.", input: "hello there", expected: "Hello there."),
        Case(name: "code fence", output: "```\nHello there.\n```", input: "hello there", expected: "Hello there."),
        Case(name: "fence with language", output: "```text\nHello there.\n```", input: "hello there", expected: "Hello there."),
        Case(name: "quotes the input lacked", output: "\"Hello there.\"", input: "hello there", expected: "Hello there."),
        Case(name: "curly quotes the input lacked", output: "“Hello there.”", input: "hello there", expected: "Hello there."),
        Case(name: "quotes the input had", output: "\"Hello there.\"", input: "\"hello there\"", expected: "\"Hello there.\""),
        Case(name: "preamble line", output: "Here is the cleaned text:\nHello there.", input: "hello there", expected: "Hello there."),
        Case(name: "sure preamble", output: "Sure, here's the cleaned transcript:\n\nHello there.", input: "hello there", expected: "Hello there."),
        Case(name: "closing line", output: "Hello there.\nLet me know if you need anything else.", input: "hello there", expected: "Hello there."),
        Case(name: "closing kept when spoken", output: "Hello.\nLet me know what you think.", input: "hello let me know what you think", expected: "Hello.\nLet me know what you think."),
        Case(name: "bold", output: "**Budget:**\n- Rice", input: "budget rice", expected: "Budget:\n- Rice"),
        Case(name: "backticks", output: "Run `git status` now.", input: "run git status now", expected: "Run git status now."),
        Case(name: "star bullets", output: "Shopping:\n* Milk\n* Eggs", input: "shopping milk eggs", expected: "Shopping:\n- Milk\n- Eggs"),
        Case(name: "dash bullets stay", output: "Shopping:\n- Milk\n- Eggs", input: "shopping milk eggs", expected: "Shopping:\n- Milk\n- Eggs"),
        Case(name: "json wrapper", output: "{\"transcript\": \"Hello there.\"}", input: "hello there", expected: "Hello there."),
        Case(name: "json text wrapper", output: "{\"text\": \"Hello there.\"}", input: "hello there", expected: "Hello there."),
        Case(name: "whitespace", output: "\n\n  Hello there.  \n", input: "hello there", expected: "Hello there."),
    ]

    @Test(arguments: accepts)
    func sanitizes(_ c: Case) {
        #expect(OutputSanitizer.sanitize(c.output, input: c.input) == .success(c.expected), "\(c.name)")
    }

    @Test(arguments: [
        ("{\"answer\": \"Hello\"}", FallbackReason.wrapper),
        ("{\"transcript\": \"a\", \"extra\": 1}", .wrapper),
        ("{not json at all", .wrapper),
        ("", .empty),
        ("   \n  ", .empty),
        ("<think>never closed", .empty),
        ("```\n```", .empty),
        ("<think>x</think>", .empty),
        ("**", .empty),
    ])
    func rejects(_ output: String, _ reason: FallbackReason) {
        #expect(OutputSanitizer.sanitize(output, input: "hello there") == .failure(reason))
    }
}
