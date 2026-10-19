import Testing
@testable import FormatterCore

@Suite("FillerCleaner and SkipRule")
struct FillerCleanerTests {
    struct Case: Sendable {
        let context: FormatterContext
        let input: String
        let expected: String
    }

    static let cases: [Case] = [
        Case(context: .email, input: "hi Maya um I wanted to follow up uh on the invoice", expected: "hi Maya I wanted to follow up on the invoice"),
        Case(context: .email, input: "so, um, the report is ready", expected: "so, the report is ready"),
        Case(context: .email, input: "I I think the the budget works", expected: "I think the budget works"),
        Case(context: .email, input: "we should go go go now", expected: "we should go now"),
        // Words longer than 4 letters are not collapsed, and punctuation between repeats blocks it.
        Case(context: .email, input: "that was really really good", expected: "that was really really good"),
        Case(context: .email, input: "no, no, that is wrong", expected: "no, no, that is wrong"),
        // "you know" and "like" only when set off by commas.
        Case(context: .email, input: "it is, you know, a long story", expected: "it is, a long story"),
        Case(context: .email, input: "you know, it is a long story", expected: "it is a long story"),
        Case(context: .email, input: "you know the answer to that", expected: "you know the answer to that"),
        Case(context: .email, input: "it was, like, really big", expected: "it was, really big"),
        Case(context: .email, input: "I like the plan a lot", expected: "I like the plan a lot"),
        // Leading so/okay only in chat.
        Case(context: .chat, input: "okay so the dinner is at seven", expected: "the dinner is at seven"),
        Case(context: .email, input: "okay so the dinner is at seven", expected: "okay so the dinner is at seven"),
        Case(context: .agent, input: "so run the tests now", expected: "so run the tests now"),
        // A short chat take keeps its opener.
        Case(context: .chat, input: "okay sounds good", expected: "okay sounds good"),
        // Self-corrections stay for the model.
        Case(context: .chat, input: "at five no wait six", expected: "at five no wait six"),
    ]

    @Test(arguments: cases)
    func cleans(_ c: Case) {
        #expect(FillerCleaner.clean(c.input, context: c.context) == c.expected)
    }

    @Test func isIdempotent() {
        for c in Self.cases {
            let once = FillerCleaner.clean(c.input, context: c.context)
            #expect(FillerCleaner.clean(once, context: c.context) == once)
        }
    }

    // MARK: Skip rule

    @Test(arguments: [
        ("thanks", true), ("thanks a lot", true), ("thanks a lot man", false), ("", true), ("  ", true),
        ("a - b", true), ("one two three four", false),
    ])
    func skipsUnderFourWords(_ text: String, _ skip: Bool) {
        #expect(SkipRule.shouldSkip(text) == skip)
    }

    @Test func formatsShortTakes() {
        #expect(SkipRule.format("thanks a lot", context: .email) == "Thanks a lot.")
        #expect(SkipRule.format("thanks a lot", context: .chat) == "Thanks a lot")
        #expect(SkipRule.format("thanks a lot!", context: .email) == "Thanks a lot!")
        #expect(SkipRule.format("i agree", context: .email) == "I agree")
        #expect(SkipRule.format("ok i'm in", context: .notes) == "Ok I'm in.")
        #expect(SkipRule.format("yes", context: .plain) == "Yes")
        #expect(SkipRule.format("", context: .plain) == "")
        #expect(SkipRule.format("3 PM today", context: .plain) == "3 PM today.")
    }
}
