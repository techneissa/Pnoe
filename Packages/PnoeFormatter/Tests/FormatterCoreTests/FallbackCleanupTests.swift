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

    @Test func aTakeEndingInAnExactSpanGetsNoPeriod() {
        #expect(FallbackCleanup.clean("please open /etc/pnoe/config.toml", context: .plain) == "Please open /etc/pnoe/config.toml")
        #expect(FallbackCleanup.clean("the report is at https://example.com/reports/q3", context: .plain)
            == "The report is at https://example.com/reports/q3")
        #expect(FallbackCleanup.clean("send it to sam@example.com", context: .plain) == "Send it to sam@example.com")
        #expect(FallbackCleanup.clean("please open src/app/main.swift", context: .plain) == "Please open src/app/main.swift")
        #expect(FallbackCleanup.clean("the slow function is parseTranscript", context: .plain) == "The slow function is parseTranscript")
    }

    @Test func aTakeEndingInANumberStillGetsItsPeriod() {
        #expect(FallbackCleanup.clean("see you at 3", context: .plain) == "See you at 3.")
        #expect(FallbackCleanup.clean("the total is twelve thousand five hundred", context: .plain) == "The total is 12,500.")
    }

    @Test func aSpanInTheMiddleDoesNotStopThePeriod() {
        #expect(FallbackCleanup.clean("please open src/app/main.swift today", context: .plain) == "Please open src/app/main.swift today.")
    }

    @Test func aFirstWordWithACapitalInsideKeepsItsSpelling() {
        #expect(FallbackCleanup.apply("iPhone battery is dying again", context: .plain) == "iPhone battery is dying again.")
        #expect(FallbackCleanup.apply("macOS updates are slow", context: .plain) == "macOS updates are slow.")
        #expect(FallbackCleanup.apply("eBay sent the parcel", context: .plain) == "eBay sent the parcel.")
        #expect(FallbackCleanup.apply("sam sent the parcel", context: .plain) == "Sam sent the parcel.")
    }

    @Test func aVocabularyTermAtTheStartKeepsItsSpellingAndIsRestored() {
        #expect(FallbackCleanup.clean("pnoe is great today", context: .plain, vocabulary: ["Pnoe"]) == "Pnoe is great today.")
        #expect(FallbackCleanup.clean("snippetkeepa is where to send it", context: .plain, vocabulary: ["snippetkeepa"])
            == "snippetkeepa is where to send it.")
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

    @Test func aFallbackThatEndsInAPathHasNoPeriodAfterIt() async throws {
        let outcome = await (try pipeline(FakeRuntime(throwing: .crashed))).format("um please open the file at /etc/pnoe/config.toml", context: .plain)
        #expect(outcome.reason == .runtimeCrashed)
        #expect(outcome.text == "Please open the file at /etc/pnoe/config.toml")
    }

    @Test func aFallbackThatEndsInANumberHasItsPeriod() async throws {
        let outcome = await (try pipeline(FakeRuntime(throwing: .crashed))).format("um let us all meet in the lobby at 3", context: .plain)
        #expect(outcome.text == "Let us all meet in the lobby at 3.")
    }

    @Test func aChatFallbackKeepsTheTakeWithoutAFinalPeriod() async throws {
        let outcome = await (try pipeline(FakeRuntime(throwing: .crashed))).format("um okay see you at noon then", context: .chat)
        #expect(outcome.text.hasSuffix("noon then"))
        #expect(outcome.text.first?.isUppercase == true)
    }
}
