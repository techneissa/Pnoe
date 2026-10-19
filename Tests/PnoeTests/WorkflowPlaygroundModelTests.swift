import XCTest

@MainActor
final class WorkflowPlaygroundModelTests: XCTestCase {
    private var directory: URL!
    private var store: PlaygroundExampleStore!

    private let cleaned = PlaygroundWorkflow(id: UUID(), name: "Cleaned Text", symbol: "text.badge.checkmark", template: .cleanedText)
    private let summary = PlaygroundWorkflow(id: UUID(), name: "Summary", symbol: "text.alignleft", template: .summary)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pnoe-playground-model-\(UUID().uuidString)")
        store = PlaygroundExampleStore(fileURL: directory.appendingPathComponent("examples.jsonl"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func model(
        workflows: [PlaygroundWorkflow]? = nil,
        runner: @escaping WorkflowPlaygroundModel.Runner = { text, _ in
            PlaygroundOutcome(output: text.capitalized + ".", duration: 1.26)
        }
    ) -> WorkflowPlaygroundModel {
        WorkflowPlaygroundModel(workflows: workflows ?? [cleaned, summary], store: store, runner: runner)
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
        let model = model { text, workflow in
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
        let model = model { text, _ in PlaygroundOutcome(output: text, duration: 2, fallbackReason: "dropped") }
        model.input = "send the file to Sam on Friday"
        await model.run()
        XCTAssertEqual(model.fallbackSentence, PlaygroundFallbackText.sentence(forCode: "dropped"))
    }

    func testAFallbackCodeOnAnotherWorkflowShowsNoReason() async {
        let model = model { text, _ in PlaygroundOutcome(output: text, duration: 2, fallbackReason: "dropped") }
        model.input = "send the file to Sam on Friday"
        model.selectedWorkflowID = summary.id
        await model.run()
        XCTAssertNil(model.fallbackSentence)
        XCTAssertNotNil(model.savedPairsAreScoredNote)
    }

    func testAFailedRunShowsTheMessage() async {
        struct Boom: LocalizedError { var errorDescription: String? { "No model is running." } }
        let model = model { _, _ in throw Boom() }
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
        XCTAssertEqual(store.load().examples.count, 1)
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
        let blocker = directory.appendingPathComponent("blocker")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: blocker)
        let blocked = PlaygroundExampleStore(fileURL: blocker.appendingPathComponent("examples.jsonl"))
        let model = WorkflowPlaygroundModel(workflows: [cleaned], store: blocked) { text, _ in
            PlaygroundOutcome(output: text, duration: 0.1)
        }
        model.input = "open the file"
        await model.run()
        model.saveExample()
        XCTAssertTrue(model.examples.isEmpty)
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
        XCTAssertEqual(PlaygroundExampleStore(fileURL: destination).load().examples.count, 2)

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

    func testAStaleRunDoesNotOverwriteANewerOne() async throws {
        let model = model { text, _ in
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

    func testCancelReturnsToIdle() async throws {
        let model = model { text, _ in
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
