import XCTest

@MainActor
final class WorkflowPlaygroundModelTests: XCTestCase {
    private var directory: URL!
    private var store: PlaygroundExampleStore!

    private let gemma = PlaygroundModelChoice(provider: "Ollama", model: "gemma3:4b")
    private let qwen = PlaygroundModelChoice(provider: "Ollama", model: "qwen3:4b")
    private let claude = PlaygroundModelChoice(provider: "Anthropic", model: "claude-haiku-5-5")
    private lazy var cleaned = PlaygroundWorkflow(
        id: UUID(), name: "Cleaned Text", symbol: "text.badge.checkmark", template: .cleanedText, defaultChoice: gemma)
    private lazy var summary = PlaygroundWorkflow(
        id: UUID(), name: "Summary", symbol: "text.alignleft", template: .summary, defaultChoice: claude)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pnoe-playground-model-\(UUID().uuidString)")
        store = PlaygroundExampleStore(fileURL: directory.appendingPathComponent("examples.jsonl"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func model(
        workflows: [PlaygroundWorkflow]? = nil,
        runner: @escaping WorkflowPlaygroundModel.Runner = { text, _, _ in
            PlaygroundOutcome(output: text.capitalized + ".", duration: 1.26)
        }
    ) -> WorkflowPlaygroundModel {
        WorkflowPlaygroundModel(
            workflows: workflows ?? [cleaned, summary], modelChoices: [gemma, qwen, claude], store: store, runner: runner)
    }

    func testStartsOnTheFirstWorkflowAndCannotRunWithoutText() {
        let model = model()
        XCTAssertEqual(model.selectedWorkflowID, cleaned.id)
        XCTAssertFalse(model.canRun)
        model.input = "  \n "
        XCTAssertFalse(model.canRun)
        model.input = "hello there"
        XCTAssertTrue(model.canRun)
    }

    func testNoWorkflowsMeansNothingToRun() async {
        let model = model(workflows: [])
        model.input = "hello there"
        XCTAssertNil(model.selectedWorkflow)
        XCTAssertFalse(model.canRun)
        await model.run()
        XCTAssertEqual(model.phase, .idle)
    }

    func testRunShowsInputResultAndTimeTaken() async throws {
        let model = model()
        model.input = "  open the file  "
        await model.run()
        let finished = try XCTUnwrap(model.finished)
        XCTAssertEqual(finished.input, "open the file")
        XCTAssertEqual(finished.outcome.output, "Open The File.")
        XCTAssertEqual(finished.outcome.duration, 1.26)
        XCTAssertEqual(model.editedResult, "Open The File.")
        XCTAssertEqual(WorkflowPlaygroundView.seconds(finished.outcome.duration), "1.3 s")
        XCTAssertNil(model.fallbackSentence)
    }

    func testRunUsesTheSelectedWorkflow() async {
        var seen: [String] = []
        let model = model { text, workflow, _ in
            seen.append(workflow.name)
            return PlaygroundOutcome(output: text, duration: 0.1)
        }
        model.input = "one two three"
        await model.run()
        model.selectedWorkflowID = summary.id
        await model.run()
        XCTAssertEqual(seen, ["Cleaned Text", "Summary"])
    }

    func testCleanedTextFallbackShowsTheReason() async {
        let model = model { text, _, _ in PlaygroundOutcome(output: text, duration: 2, fallbackReason: "dropped") }
        model.input = "send the file to Sam on Friday"
        await model.run()
        XCTAssertEqual(model.fallbackSentence, "The model changed your wording. Pnoe's own cleanup was used.")
    }

    func testAFallbackCodeOnAnotherWorkflowShowsNoReason() async {
        let model = model { text, _, _ in PlaygroundOutcome(output: text, duration: 2, fallbackReason: "dropped") }
        model.input = "send the file to Sam on Friday"
        model.selectedWorkflowID = summary.id
        await model.run()
        XCTAssertNil(model.fallbackSentence)
        XCTAssertNotNil(model.savedPairsAreScoredNote)
    }

    func testAFailedRunShowsTheMessage() async {
        struct Boom: LocalizedError { var errorDescription: String? { "No model is running." } }
        let model = model { _, _, _ in throw Boom() }
        model.input = "hello there"
        await model.run()
        XCTAssertEqual(model.phase, .failed("No model is running."))
        XCTAssertNil(model.finished)
    }

    func testSaveAsIsKeepsTheOutputAndThePairThatWasRun() async throws {
        let model = model()
        model.input = "open the file"
        await model.run()
        model.input = "typed something else afterwards"
        model.saveExample()
        let saved = try XCTUnwrap(model.examples.first)
        XCTAssertEqual(saved.raw, "open the file")
        XCTAssertEqual(saved.expected, "Open The File.")
        XCTAssertFalse(saved.wasEdited)
        XCTAssertEqual(saved.workflowTag, "workflow:cleanedText")
        XCTAssertEqual(saved.workflow, "Cleaned Text")
        XCTAssertEqual(model.notice, "Saved as it is.")
        XCTAssertEqual(try store.load().examples.count, 1)
    }

    func testSaveEditedKeepsTheEditAndRemembersTheOutput() async throws {
        let model = model()
        model.input = "open the file"
        await model.run()
        XCTAssertFalse(model.resultWasEdited)
        model.editedResult = "Open the file."
        XCTAssertTrue(model.resultWasEdited)
        model.saveExample()
        let saved = try XCTUnwrap(model.examples.first)
        XCTAssertEqual(saved.expected, "Open the file.")
        XCTAssertEqual(saved.output, "Open The File.")
        XCTAssertTrue(saved.wasEdited)
        XCTAssertEqual(model.notice, "Saved your edited result.")
    }

    func testSavingAnEmptyResultIsRefused() async {
        let model = model()
        model.input = "open the file"
        await model.run()
        model.editedResult = "  "
        model.saveExample()
        XCTAssertTrue(model.examples.isEmpty)
        XCTAssertEqual(model.notice, "Nothing to save: the result is empty.")
    }

    func testSaveWithoutARunDoesNothing() {
        let model = model()
        model.input = "open the file"
        model.saveExample()
        XCTAssertTrue(model.examples.isEmpty)
        XCTAssertNil(model.notice)
    }

    func testSaveFailureIsReportedNotThrown() async throws {
        // A folder where the file should be: reading it fails, so nothing may be written.
        let blocked = PlaygroundExampleStore(fileURL: directory.appendingPathComponent("examples.jsonl"))
        try FileManager.default.createDirectory(at: blocked.fileURL, withIntermediateDirectories: true)
        let model = WorkflowPlaygroundModel(workflows: [cleaned], store: blocked) { text, _, _ in
            PlaygroundOutcome(output: text, duration: 0.1)
        }
        model.input = "open the file"
        await model.run()
        model.saveExample()
        XCTAssertTrue(model.examples.isEmpty)
        XCTAssertNotNil(model.loadError)
        XCTAssertTrue(model.notice?.hasPrefix("Could not save") == true)
    }

    func testDeleteAndExport() async throws {
        let model = model()
        model.input = "open the file"
        await model.run()
        model.saveExample()
        model.saveExample()
        XCTAssertEqual(model.examples.count, 2)

        let destination = directory.appendingPathComponent("out.jsonl")
        model.export(to: destination)
        XCTAssertEqual(model.notice, "Exported 2 pairs.")
        XCTAssertEqual(try PlaygroundExampleStore(fileURL: destination).load().examples.count, 2)

        model.delete(model.examples[0])
        XCTAssertEqual(model.examples.count, 1)
        XCTAssertEqual(model.notice, "Deleted.")
    }

    func testReloadPicksUpAMalformedLineCount() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "broken\n".write(to: store.fileURL, atomically: true, encoding: .utf8)
        let model = model()
        XCTAssertEqual(model.unreadableLines, 1)
        XCTAssertTrue(model.examples.isEmpty)
    }

    func testRejectedTextIsDiffedAgainstTheTakeTheModelGot() async throws {
        let model = model { text, _, _ in
            PlaygroundOutcome(
                output: text, duration: 1, fallbackReason: "new_words",
                rejectedText: "Open the file on Thursday and email Sam please.")
        }
        model.input = "um open the file on thursday and send it to Sam please"
        await model.run()
        let segments = try XCTUnwrap(model.rejectedDiff)
        XCTAssertFalse(segments.contains { $0.word == "um" }, "fillers were already out when the model saw the take")
        XCTAssertEqual(segments.filter { $0.kind == .added }.map(\.word), ["email"])
        XCTAssertEqual(segments.filter { $0.kind == .missing }.map(\.word), ["send", "it", "to"])
    }

    func testNoRejectedDiffWithoutAFallbackOrOnAnotherWorkflow() async {
        let model = model { text, _, _ in
            PlaygroundOutcome(output: text, duration: 1, fallbackReason: "dropped", rejectedText: "something else")
        }
        model.input = "open the file on thursday please"
        model.selectedWorkflowID = summary.id
        await model.run()
        XCTAssertNil(model.rejectedDiff)
        model.selectedWorkflowID = cleaned.id
        await model.run()
        XCTAssertNotNil(model.rejectedDiff)

        let passing = self.model()
        passing.input = "open the file on thursday please"
        await passing.run()
        XCTAssertNil(passing.rejectedDiff)
    }

    func testEditingTheSampleAfterARunMarksTheResultStale() async {
        let model = model()
        model.input = "open the file"
        await model.run()
        XCTAssertFalse(model.resultIsStale)
        model.input = "open the other file"
        XCTAssertTrue(model.resultIsStale)
    }

    func testASkippedRunKeepsTheTranscriptAsTheResult() async {
        let model = model { text, _, _ in
            PlaygroundOutcome(output: text, duration: 0, skippedReason: "Too short.")
        }
        model.input = "ok"
        await model.run()
        XCTAssertEqual(model.finished?.outcome.skippedReason, "Too short.")
        XCTAssertNil(model.fallbackSentence)
        XCTAssertEqual(model.editedResult, "ok")
    }

    func testARunStartsOnTheWorkflowsOwnModelAndAPickedOneIsUsedForThatRunOnly() async {
        var seen: [String?] = []
        let model = model { text, _, choice in
            seen.append(choice?.label)
            return PlaygroundOutcome(output: text, duration: 1)
        }
        model.input = "open the file on thursday please"
        XCTAssertEqual(model.selectedChoice, gemma)
        await model.run()

        model.pick(qwen)
        XCTAssertEqual(model.selectedChoice, qwen)
        await model.run()
        XCTAssertEqual(model.finished?.choice, qwen)

        XCTAssertEqual(seen, ["Ollama · gemma3:4b", "Ollama · qwen3:4b"])
        // The workflow keeps its own provider and model.
        XCTAssertEqual(model.selectedWorkflow?.defaultChoice, gemma)
        XCTAssertEqual(model.workflows.first { $0.id == cleaned.id }, cleaned)
    }

    func testAPickedModelDoesNotCarryOverToAnotherWorkflow() {
        let model = model()
        model.pick(qwen)
        XCTAssertEqual(model.selectedChoice, qwen)
        model.selectedWorkflowID = summary.id
        XCTAssertEqual(model.selectedChoice, claude)
        model.selectedWorkflowID = cleaned.id
        XCTAssertEqual(model.selectedChoice, gemma)
    }

    func testTheMenuListsTheWorkflowsOwnModelFirstEvenWhenItIsNotInTheList() {
        let local = PlaygroundModelChoice(provider: "Ollama", model: "old-model:1b")
        let own = PlaygroundWorkflow(id: UUID(), name: "Old", template: .cleanedText, defaultChoice: local)
        let model = WorkflowPlaygroundModel(workflows: [own], modelChoices: [gemma, qwen], store: store) { text, _, _ in
            PlaygroundOutcome(output: text, duration: 0)
        }
        XCTAssertEqual(model.menuChoices, [local, gemma, qwen])
        XCTAssertEqual(model.selectedChoice, local)
    }

    func testAWorkflowWithNoUsableModelHasNoSelectionUntilOnePicks() {
        let none = PlaygroundWorkflow(id: UUID(), name: "Bare", template: nil, defaultChoice: nil)
        let model = WorkflowPlaygroundModel(workflows: [none], modelChoices: [gemma], store: store) { text, _, _ in
            PlaygroundOutcome(output: text, duration: 0)
        }
        XCTAssertNil(model.selectedChoice)
        model.pick(gemma)
        XCTAssertEqual(model.selectedChoice, gemma)
    }

    func testASavedExampleKeepsTheModelItRanOn() async throws {
        let model = model()
        model.input = "open the file on thursday please"
        model.pick(qwen)
        await model.run()
        model.saveExample()
        XCTAssertEqual(model.examples.first?.model, "qwen3:4b")
        XCTAssertEqual(try store.load().examples.first?.model, "qwen3:4b")
    }

    func testTheTimeLineNamesTheModelAndTheModelIsOnTheFinishedRun() async {
        let model = model()
        model.input = "open the file on thursday please"
        await model.run()
        XCTAssertEqual(model.finished?.choice?.modelName, "gemma3:4b")
        XCTAssertEqual(PlaygroundModelChoice(provider: "Local CLI", model: nil).modelName, "Local CLI")
    }

    func testAStaleRunDoesNotOverwriteANewerOne() async throws {
        let model = model { text, _, _ in
            if text == "slow one" { try await Task.sleep(nanoseconds: 300_000_000) }
            return PlaygroundOutcome(output: text.uppercased(), duration: 0.1)
        }
        model.input = "slow one"
        model.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        model.input = "fast one"
        model.start()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(model.finished?.input, "fast one")
        XCTAssertEqual(model.finished?.outcome.output, "FAST ONE")
    }

    func testTheRunMovesThroughTheMotionPhases() async throws {
        let model = model { text, _, _ in
            try await Task.sleep(nanoseconds: 200_000_000)
            return PlaygroundOutcome(output: text, duration: 0.2)
        }
        XCTAssertEqual(model.motionPhase, .idle)
        model.input = "hello there"
        model.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.motionPhase, .running)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(model.motionPhase, .finished)
    }

    func testAFallbackIsTheFailureStyleMoment() async {
        let model = model { text, _, _ in
            PlaygroundOutcome(output: text, duration: 0.3, fallbackReason: "new_words", rejectedText: "other words")
        }
        model.input = "hello there"
        await model.run()
        XCTAssertEqual(model.motionPhase, .failed)
    }

    func testAFailedRunIsTheFailureMoment() async {
        struct Boom: LocalizedError { var errorDescription: String? { "No model is running." } }
        let model = model { _, _, _ in throw Boom() }
        model.input = "hello there"
        await model.run()
        XCTAssertEqual(model.motionPhase, .failed)
    }

    func testASkippedRunIsNeitherAFinishNorAFailure() async {
        let model = model { text, _, _ in
            PlaygroundOutcome(output: text, duration: 0, skippedReason: "Too short.")
        }
        model.input = "ok"
        await model.run()
        XCTAssertEqual(model.motionPhase, .idle)
    }

    func testCancelReturnsToIdle() async throws {
        let model = model { text, _, _ in
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return PlaygroundOutcome(output: text, duration: 2)
        }
        model.input = "slow one"
        model.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.phase, .running)
        model.cancel()
        XCTAssertEqual(model.phase, .idle)
    }
}
