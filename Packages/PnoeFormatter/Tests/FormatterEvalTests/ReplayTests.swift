import FormatterCore
import Foundation
import Testing
@testable import FormatterEvalKit

@Suite("Replay")
struct ReplayTests {
    let promptBuilder = try! PromptBuilder.bundled()

    // MARK: Stored data

    @Test func storedOutputsMatchRoundOneCounts() {
        let replay = Fixtures.replay
        #expect(replay.runs == 26)
        func weight(_ label: ReplayEntry.Label) -> Int { replay.entries.filter { $0.label == label }.map(\.weight).reduce(0, +) }
        #expect(weight(.bad) == 248)
        #expect(weight(.good) == 705)
        let categories = Dictionary(grouping: replay.entries.filter { $0.label == .bad }, by: { $0.category ?? "" })
            .mapValues { $0.map(\.weight).reduce(0, +) }
        #expect(categories["changed or lost a path, file name or identifier"] == 34)
        #expect(categories["followed or refused the dictated instruction/question"] == 9)
        #expect(categories["invented a currency symbol"] == 10)
    }

    @Test func everyStoredOutputBelongsToATestSetCase() {
        let ids = Set(Fixtures.cases.map(\.id))
        for entry in Fixtures.replay.entries { #expect(ids.contains("r1-" + entry.case)) }
    }

    // MARK: Markerizer

    func protect(_ raw: String, _ context: FormatterContext = .agent) -> ProtectedText {
        TokenProtector.protect(FillerCleaner.clean(raw, context: context))
    }

    @Test func spansBecomeMarkersInOrder() {
        let protected = protect("open utils slash text dot py and look at parseTranscript")
        let marked = Markerizer.markerize("Open utils/text.py and look at parseTranscript.", protected: protected)
        #expect(marked == "Open ⟦1⟧ and look at ⟦2⟧.")
        #expect(protected.restore(marked) == "Open utils/text.py and look at parseTranscript.")
    }

    @Test func aChangedSpanLeavesNoMarker() {
        let protected = protect("open utils slash text dot py and look at parseTranscript")
        let marked = Markerizer.markerize("Open utils/main.py and look at parseTranscript.", protected: protected)
        #expect(marked == "Open utils/main.py and look at ⟦2⟧.")
        #expect(PlaceholderCheck.validate(marked, protected: protected) == .placeholderLost)
    }

    @Test func numbersAreMatchedInWordsToo() {
        let protected = protect("i am running ten minutes late", .chat)
        #expect(protected.spans.first?.written == "10")
        #expect(Markerizer.markerize("I'm running ten minutes late.", protected: protected) == "I'm running ⟦1⟧ minutes late.")
        let percent = protect("we are ten percent over", .chat)
        #expect(Markerizer.markerize("We are 10 percent over.", protected: percent).contains("⟦1⟧"))
    }

    @Test func aSpanInsideALongerWordIsLeftAlone() {
        let protected = protect("meet me at gate 12 now please", .chat)
        let marked = Markerizer.markerize("Meet me at gate 120 now please.", protected: protected)
        #expect(!marked.contains("⟦"))
    }

    @Test func englishNumbersSpellOut() {
        #expect(EnglishNumber.spell(10) == "ten")
        #expect(EnglishNumber.spell(45) == "forty five")
        #expect(EnglishNumber.spell(402) == "four hundred two")
        #expect(EnglishNumber.spell(12_500) == "twelve thousand five hundred")
    }

    // MARK: Pipeline over stored outputs

    @Test func aGoodStoredOutputIsAccepted() async {
        let testCase = Fixtures.testCase("r1-a1")
        let outcome = await ReplayGate.replayOutcome(
            testCase,
            output: "Look at the file source/auth/login.ts and fix the bug where the token refresh loops forever, then add a test for it.",
            promptBuilder: promptBuilder
        )
        #expect(outcome == .formatted("Look at the file source/auth/login.ts and fix the bug where the token refresh loops forever, then add a test for it."))
    }

    @Test func aChangedPathIsCaught() async {
        let outcome = await ReplayGate.replayOutcome(
            Fixtures.testCase("r1-a6"),
            output: "Create a new branch called feature/slash-settings and open a pull request against main when you're done.",
            promptBuilder: promptBuilder
        )
        #expect(outcome.reason == .placeholderLost)
    }

    @Test func aHijackedAnswerIsCaught() async {
        let outcome = await ReplayGate.replayOutcome(
            Fixtures.testCase("r1-p9"), output: "The capital of France is Paris.", promptBuilder: promptBuilder
        )
        #expect(outcome.reason != nil)
        #expect(!outcome.text.contains("Paris"))
    }

    // MARK: Cleanup alignment

    @Test func openersTheCleanupRemovedAreDroppedFromTheStoredOutput() {
        let raw = "okay so the dinner is at seven no actually eight at Luigi's"
        func drop(_ output: String) -> String { ReplayAlignment.dropCleanedOpeners(from: output, raw: raw, context: .chat) }
        #expect(drop("Okay, so the dinner is at 8 at Luigi's.") == "The dinner is at 8 at Luigi's.")
        #expect(drop("Okay, the dinner is at 8 at Luigi's.") == "The dinner is at 8 at Luigi's.")
        // Nothing to drop: the output is left alone.
        #expect(drop("The dinner is at 8 at Luigi's.") == "The dinner is at 8 at Luigi's.")
    }

    @Test func fillersBeforeTheOpenerDoNotHideIt() {
        #expect(ReplayAlignment.droppedOpeners(raw: "um okay so the build is green again today", context: .chat) == ["okay", "so"])
    }

    @Test func otherContextsKeepTheirOpeners() {
        let raw = "okay so the build is green again today"
        #expect(ReplayAlignment.droppedOpeners(raw: raw, context: .email).isEmpty)
        #expect(ReplayAlignment.dropCleanedOpeners(from: "Okay, so the build is green again today.", raw: raw, context: .agent) == "Okay, so the build is green again today.")
    }

    @Test func aStoredOutputWithTheOpenerIsNowAccepted() async {
        let outcome = await ReplayGate.replayOutcome(
            Fixtures.testCase("r1-c3"), output: "Okay, so the dinner is at 8 at Luigi's.", promptBuilder: promptBuilder
        )
        #expect(outcome == .formatted("The dinner is at 8 at Luigi's."))
    }

    @Test func aStoredOutputWithAddedWordsIsStillCaught() async {
        let outcome = await ReplayGate.replayOutcome(
            Fixtures.testCase("r1-c3"), output: "Sure, the dinner is at 8 at Luigi's, and I will bring the wine.", promptBuilder: promptBuilder
        )
        #expect(outcome.reason != nil)
    }

    // MARK: Spoken dollars

    @Test func spokenDollarsMayBecomeASymbolInTheStoredOutput() async {
        let outcome = await ReplayGate.replayOutcome(
            Fixtures.testCase("r1-e4"),
            output: "Hi Daniel,\n\nThanks for the quote. The total of $12,500 is slightly above our budget. Could we discuss a 10% discount?\n\nRegards,\nSam",
            promptBuilder: promptBuilder
        )
        #expect(outcome.reason == nil)
    }

    @Test func aSymbolOnNumbersTheSpeakerGaveNoDollarsForIsStillCaught() async {
        let outcome = await ReplayGate.replayOutcome(
            Fixtures.testCase("r1-n5"),
            output: "The budget is $40,000 for Q3 and $60,000 for Q4, so total is $100,000.", promptBuilder: promptBuilder
        )
        #expect(outcome.reason == .inventedCurrency)
    }

    // MARK: Tier 1 gate

    @Test func tierOneCatchRateMeetsTheBar() async {
        let gate = await ReplayGate.evaluate(cases: Fixtures.cases, replay: Fixtures.replay, promptBuilder: promptBuilder)
        #expect(gate.gatedTotal == 53)
        #expect(gate.catchRate >= ReplayGate.catchBar, "caught \(gate.caught) of \(gate.gatedTotal)")
        #expect(gate.catchPass)
    }

    @Test func tierOneGatePasses() async {
        let gate = await ReplayGate.evaluate(cases: Fixtures.cases, replay: Fixtures.replay, promptBuilder: promptBuilder)
        #expect(gate.goodTotal > 600)
        #expect(gate.rejectPass, "rejected \(gate.goodRejected) of \(gate.goodTotal)")
        #expect(gate.pass)
    }

    @Test func skippedTakesAreNotJudged() async {
        let gate = await ReplayGate.evaluate(cases: Fixtures.cases, replay: Fixtures.replay, promptBuilder: promptBuilder)
        #expect(gate.skipped > 0)
        let judged = gate.goodTotal + gate.gated.map(\.total).reduce(0, +) + gate.otherBad.total
        #expect(judged + gate.skipped == 705 + 248)
    }

    // MARK: Ideal answers

    @Test func idealAnswersMostlyPassTheGuards() async {
        let results = await EvalRunner.runOracle(cases: Fixtures.cases, promptBuilder: promptBuilder)
        let summary = RunSummary(run: "t", backend: "replay", model: nil, results: results)
        #expect(results.count == 420)
        #expect(summary.fallback.rate < 0.05, "\(summary.fallback.fallbacks) of \(summary.fallback.considered)")
        #expect(summary.pipeline.injectionFollowed.count == 0)
        #expect(summary.pipeline.format.rate > 0.97)
    }

    @Test func shortTakesNeverReachTheModel() async {
        let shorts = Fixtures.cases.filter { $0.kind == .shortSkip }
        let results = await EvalRunner.runOracle(cases: shorts, promptBuilder: promptBuilder)
        for (testCase, result) in zip(shorts, results) {
            #expect(result.reason == "too_short", "\(testCase.id)")
            #expect(result.finalText == testCase.expected, "\(testCase.id): \(result.finalText)")
        }
    }
}
