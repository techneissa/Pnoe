import FormatterCore
import XCTest

final class PlaygroundExampleStoreTests: XCTestCase {
    private var directory: URL!
    private var store: PlaygroundExampleStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pnoe-playground-\(UUID().uuidString)")
        store = PlaygroundExampleStore(fileURL: directory.appendingPathComponent("nested/examples.jsonl"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func example(
        _ id: String, raw: String = "um open the file on thursday", output: String = "Open the file on Thursday.",
        expected: String? = nil, template: LocalWorkflowTemplate? = .cleanedText
    ) -> PlaygroundExample {
        PlaygroundExample.make(
            raw: raw, output: output, expected: expected ?? output, workflowName: "Cleaned Text", template: template,
            id: id, now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func fileLines() throws -> [String] {
        try String(contentsOf: store.fileURL, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func testMissingFileLoadsAsEmpty() {
        XCTAssertEqual(store.load(), PlaygroundExampleStore.Loaded(examples: [], unreadableLines: 0))
    }

    func testAppendCreatesTheFolderAndKeepsOrder() throws {
        try store.append(example("mine-a"))
        try store.append(example("mine-b", raw: "second take here"))
        let loaded = store.load()
        XCTAssertEqual(loaded.examples.map(\.id), ["mine-a", "mine-b"])
        XCTAssertEqual(loaded.examples[1].raw, "second take here")
        XCTAssertEqual(try fileLines().count, 2)
    }

    func testAPairSavedAsIsIsNotEditedAndAnEditedOneIs() throws {
        try store.append(example("mine-a"))
        try store.append(example("mine-b", expected: "Open the file on Thursday, please."))
        let loaded = store.load().examples
        XCTAssertFalse(loaded[0].wasEdited)
        XCTAssertTrue(loaded[1].wasEdited)
        XCTAssertEqual(loaded[1].output, "Open the file on Thursday.")
    }

    func testLineIsATestSetCaseThatKeepsMultilineText() throws {
        try store.append(example("mine-a", raw: "first call Sam\nsecond send the file", expected: "- Call Sam\n- Send the file"))
        let line = try XCTUnwrap(fileLines().first)
        XCTAssertFalse(line.contains("\n"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        for key in ["id", "context", "raw", "expected", "protected", "kind", "tags", "must_contain", "must_not"] {
            XCTAssertNotNil(json[key], key)
        }
        XCTAssertEqual(json["context"] as? String, "plain")
        XCTAssertEqual(json["kind"] as? String, "format")
        XCTAssertEqual(json["tags"] as? [String], ["personal", "workflow:cleanedText"])
        XCTAssertEqual(json["expected"] as? String, "- Call Sam\n- Send the file")
        XCTAssertEqual(store.load().examples.first?.raw, "first call Sam\nsecond send the file")
    }

    func testTagNamesTheWorkflowTemplate() {
        XCTAssertEqual(example("a").workflowTag, "workflow:cleanedText")
        XCTAssertEqual(example("a", template: .summary).workflowTag, "workflow:summary")
        XCTAssertEqual(example("a", template: nil).workflowTag, "workflow:custom")
        XCTAssertEqual(LocalWorkflowTemplate.template(forPromptId: LocalWorkflowTemplate.summary.promptId), .summary)
        XCTAssertNil(LocalWorkflowTemplate.template(forPromptId: UUID()))
        XCTAssertNil(LocalWorkflowTemplate.template(forPromptId: nil))
    }

    func testEmptyTextIsRefusedAndNothingIsWritten() {
        XCTAssertThrowsError(try store.append(example("a", raw: "  \n"))) {
            XCTAssertEqual($0 as? PlaygroundExampleStore.StoreError, .emptyText)
        }
        XCTAssertThrowsError(try store.append(example("a", expected: " "))) {
            XCTAssertEqual($0 as? PlaygroundExampleStore.StoreError, .emptyText)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testUpdateExpectedChangesOnlyThatPair() throws {
        try store.append(example("mine-a"))
        try store.append(example("mine-b"))
        try store.updateExpected(id: "mine-b", to: "Open the file Thursday.")
        let loaded = store.load().examples
        XCTAssertEqual(loaded[0].expected, "Open the file on Thursday.")
        XCTAssertEqual(loaded[1].expected, "Open the file Thursday.")
        XCTAssertTrue(loaded[1].wasEdited)
    }

    func testUpdateExpectedRejectsEmptyTextAndUnknownIds() throws {
        try store.append(example("mine-a"))
        XCTAssertThrowsError(try store.updateExpected(id: "mine-a", to: "")) {
            XCTAssertEqual($0 as? PlaygroundExampleStore.StoreError, .emptyText)
        }
        XCTAssertThrowsError(try store.updateExpected(id: "nope", to: "x")) {
            XCTAssertEqual($0 as? PlaygroundExampleStore.StoreError, .notFound("nope"))
        }
    }

    func testDeleteRemovesOnePair() throws {
        try store.append(example("mine-a"))
        try store.append(example("mine-b"))
        try store.delete(id: "mine-a")
        XCTAssertEqual(store.load().examples.map(\.id), ["mine-b"])
        XCTAssertThrowsError(try store.delete(id: "mine-a")) {
            XCTAssertEqual($0 as? PlaygroundExampleStore.StoreError, .notFound("mine-a"))
        }
    }

    func testMalformedLinesAreCountedAndSurviveEdits() throws {
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let good = try String(
            contentsOf: {
                try store.append(example("mine-a"))
                return store.fileURL
            }(), encoding: .utf8)
        try ("not json\n" + good + "{\"id\":\"half\"}\n").write(to: store.fileURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(store.load().examples.map(\.id), ["mine-a"])
        XCTAssertEqual(store.load().unreadableLines, 2)

        try store.append(example("mine-b"))
        try store.updateExpected(id: "mine-a", to: "Open it.")
        let lines = try fileLines()
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], "not json")
        XCTAssertEqual(lines[2], "{\"id\":\"half\"}")
        XCTAssertEqual(store.load().unreadableLines, 2)

        try store.delete(id: "mine-b")
        XCTAssertEqual(try fileLines().filter { $0 == "not json" || $0 == "{\"id\":\"half\"}" }.count, 2)
    }

    func testExportWritesOnlyReadablePairs() throws {
        try store.append(example("mine-a"))
        try store.append(example("mine-b"))
        let handle = try FileHandle(forWritingTo: store.fileURL)
        handle.seekToEndOfFile()
        handle.write(Data("garbage line\n".utf8))
        try handle.close()

        let destination = directory.appendingPathComponent("export.jsonl")
        XCTAssertEqual(try store.export(to: destination), 2)
        let exported = PlaygroundExampleStore(fileURL: destination).load()
        XCTAssertEqual(exported.examples.map(\.id), ["mine-a", "mine-b"])
        XCTAssertEqual(exported.unreadableLines, 0)
        XCTAssertTrue(try String(contentsOf: destination, encoding: .utf8).hasSuffix("\n"))
    }

    func testExportOfAnEmptyStoreWritesAnEmptyFile() throws {
        let destination = directory.appendingPathComponent("empty.jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertEqual(try store.export(to: destination), 0)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "")
    }

    func testExampleIdsAreUniqueAndCarryThePrefix() {
        let a = PlaygroundExample.make(raw: "a", output: "b", expected: "b", workflowName: "W", template: nil)
        let b = PlaygroundExample.make(raw: "a", output: "b", expected: "b", workflowName: "W", template: nil)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertTrue(a.id.hasPrefix("mine-"))
    }

    func testDefaultFileLivesInApplicationSupport() {
        let url = PlaygroundExampleStore.defaultFileURL
        XCTAssertEqual(url.lastPathComponent, "playground-examples.jsonl")
        XCTAssertTrue(url.path.contains("Application Support"))
    }
}

final class PlaygroundFallbackTextTests: XCTestCase {
    func testEveryFallbackReasonHasASentenceThatSaysThePlainTranscriptWasUsed() {
        for reason in FallbackReason.allCases {
            let sentence = PlaygroundFallbackText.sentence(forCode: reason.rawValue)
            XCTAssertTrue(sentence.hasSuffix("."), reason.rawValue)
            XCTAssertFalse(sentence.contains("_"), reason.rawValue)
        }
        XCTAssertTrue(PlaygroundFallbackText.sentence(forCode: "dropped").contains("changed your words"))
        XCTAssertTrue(PlaygroundFallbackText.sentence(forCode: "timeout").contains("too long"))
    }

    func testAnUnknownCodeStillGetsASentence() {
        XCTAssertTrue(PlaygroundFallbackText.sentence(forCode: "brand_new").contains("plain transcript"))
    }
}
