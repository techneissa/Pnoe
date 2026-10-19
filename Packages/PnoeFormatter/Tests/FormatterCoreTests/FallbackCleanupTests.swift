import Foundation
import Testing
@testable import FormatterCore

@Suite("Fallback cleanup")
struct FallbackCleanupTests {
    @Test func addsACapitalAndAFinalPeriod() {
        #expect(FallbackCleanup.apply("open the file on thursday and send it to sam", context: .plain)
            == "Open the file on thursday and send it to sam.")
    }

    @Test func fixesTheWordIOnly() {
        #expect(FallbackCleanup.apply("i think i'll call sam", context: .plain) == "I think I'll call sam.")
    }

    @Test func keepsAnExistingEnding() {
        #expect(FallbackCleanup.apply("Is the file ready?", context: .plain) == "Is the file ready?")
        #expect(FallbackCleanup.apply("Send it now!", context: .email) == "Send it now!")
        #expect(FallbackCleanup.apply("Wait for it…", context: .plain) == "Wait for it…")
    }

    @Test func chatGetsNoFinalPeriod() {
        #expect(FallbackCleanup.apply("sounds good see you at noon", context: .chat) == "Sounds good see you at noon")
    }

    @Test func doesNotCapitalizeAWordThatStartsWithADigitOrAPath() {
        #expect(FallbackCleanup.apply("3 apples and 2 pears", context: .plain) == "3 apples and 2 pears.")
        #expect(FallbackCleanup.apply("/usr/bin/env is the path", context: .plain) == "/usr/bin/env is the path.")
    }

    @Test func emptyTextStaysEmpty() {
        #expect(FallbackCleanup.apply("", context: .plain) == "")
        #expect(FallbackCleanup.apply("   ", context: .plain) == "")
    }

    @Test func cleanRemovesFillersFirst() {
        #expect(FallbackCleanup.clean("um open the the file uh please", context: .plain) == "Open the file please.")
    }
}

@Suite("Pipeline fallback text")
struct PipelineFallbackTextTests {
    let take = "um please open src/app/main.swift and fix the login bug before the demo"

    func pipeline(_ runtime: FakeRuntime) throws -> FormatterPipeline {
        try FormatterPipeline.bundled(runtime: runtime)
    }

    @Test func aRuntimeFailureGivesTheCleanedTakeWithACapitalAndAPeriod() async throws {
        let outcome = await (try pipeline(FakeRuntime(throwing: .crashed))).format(take, context: .plain)
        #expect(outcome.reason == .runtimeCrashed)
        #expect(outcome.text == "Please open src/app/main.swift and fix the login bug before the demo.")
    }

    @Test func aRejectedModelTextGivesTheSameFallback() async throws {
        let outcome = await (try pipeline(FakeRuntime(returning: "Please fix the login bug before the demo."))).format(take, context: .plain)
        #expect(outcome.reason == .placeholderLost)
        #expect(outcome.text == "Please open src/app/main.swift and fix the login bug before the demo.")
    }

    @Test func aChatFallbackKeepsTheTakeWithoutAFinalPeriod() async throws {
        let outcome = await (try pipeline(FakeRuntime(throwing: .crashed))).format("um okay see you at noon then", context: .chat)
        #expect(outcome.text.hasSuffix("noon then"))
        #expect(outcome.text.first?.isUppercase == true)
    }
}
