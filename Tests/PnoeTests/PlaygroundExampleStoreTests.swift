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

    func testMissingFileLoadsAsEmpty() throws {
        XCTAssertEqual(try store.load(), PlaygroundExampleStore.Loaded(examples: [], unreadableLines: 0))
    }

    func testAppendCreatesTheFolderAndKeepsOrder() throws {
        try store.append(example("mine-a"))
        try store.append(example("mine-b", raw: "second take here"))
        let loaded = try store.load()
        XCTAssertEqual(loaded.examples.map(\.id), ["mine-a", "mine-b"])
        XCTAssertEqual(loaded.examples[1].raw, "second take here")
        XCTAssertEqual(try fileLines().count, 2)
    }

    func testAPairSavedAsIsIsNotEditedAndAnEditedOneIs() throws {
        try store.append(example("mine-a"))
        try store.append(example("mine-b", expected: "Open the file on Thursday, please."))
        let loaded = try store.load().examples
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
        XCTAssertEqual(try store.load().examples.first?.raw, "first call Sam\nsecond send the file")
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
        try store.updateExpected(of: try XCTUnwrap(try store.load().examples.last), to: "Open the file Thursday.")
        let loaded = try store.load().examples
        XCTAssertEqual(loaded[0].expected, "Open the file on Thursday.")
        XCTAssertEqual(loaded.map(\.line), [0, 1])
        XCTAssertEqual(loaded[1].expected, "Open the file Thursday.")
        XCTAssertTrue(loaded[1].wasEdited)
    }

    func testUpdateExpectedRejectsEmptyTextAndUnknownIds() throws {
        try store.append(example("mine-a"))
        let saved = try XCTUnwrap(try store.load().examples.first)
        XCTAssertThrowsError(try store.updateExpected(of: saved, to: "")) {
            XCTAssertEqual($0 as? PlaygroundExampleStore.StoreError, .emptyText)
        }
        var ghost = saved
        ghost.id = "nope"
        XCTAssertThrowsError(try store.updateExpected(of: ghost, to: "x")) {
            XCTAssertEqual($0 as? PlaygroundExampleStore.StoreError, .notFound("nope"))
        }
    }

    func testDeleteRemovesOnePair() throws {
        try store.append(example("mine-a"))
        try store.append(example("mine-b"))
        let first = try XCTUnwrap(try store.load().examples.first)
        try store.delete(first)
        XCTAssertEqual(try store.load().examples.map(\.id), ["mine-b"])
        XCTAssertThrowsError(try store.delete(first)) {
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

        XCTAssertEqual(try store.load().examples.map(\.id), ["mine-a"])
        XCTAssertEqual(try store.load().unreadableLines, 2)

        try store.append(example("mine-b"))
        try store.updateExpected(of: try XCTUnwrap(try store.load().examples.first), to: "Open it.")
        let lines = try fileLines()
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], "not json")
        XCTAssertEqual(lines[2], "{\"id\":\"half\"}")
        XCTAssertEqual(try store.load().unreadableLines, 2)

        try store.delete(try XCTUnwrap(try store.load().examples.last))
        XCTAssertEqual(try fileLines().filter { $0 == "not json" || $0 == "{\"id\":\"half\"}" }.count, 2)
    }

    func testALineWithANonUTF8ByteIsUnreadableAndKeptByteForByte() throws {
        try store.append(example("mine-a"))
        let bad = Data("{\"id\":\"bad".utf8) + Data([0xFF, 0xFE]) + Data("\"}\n".utf8)
        let handle = try FileHandle(forWritingTo: store.fileURL)
        handle.seekToEndOfFile()
        handle.write(bad)
        try handle.close()

        let loaded = try store.load()
        XCTAssertEqual(loaded.examples.map(\.id), ["mine-a"])
        XCTAssertEqual(loaded.unreadableLines, 1)

        try store.append(example("mine-b"))
        try store.delete(try XCTUnwrap(try store.load().examples.first))
        let bytes = try Data(contentsOf: store.fileURL)
        XCTAssertTrue(bytes.range(of: Data([0xFF, 0xFE])) != nil, "the unreadable line stays as it was")
        XCTAssertEqual(try store.load().examples.map(\.id), ["mine-b"])
        XCTAssertEqual(try store.load().unreadableLines, 1)
    }

    func testAFileThatCannotBeReadIsNeverOverwritten() throws {
        // A folder where the file should be: it exists, so it is not "missing", and reading it fails.
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.append(example("mine-a")))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "nothing was written over it")
    }

    func testDeleteRemovesOnlyTheChosenLineWhenAnIdIsRepeated() throws {
        try store.append(example("mine-dup", raw: "first take of the sentence"))
        try store.append(example("mine-dup", raw: "second take of the sentence"))
        try store.append(example("mine-other"))
        let loaded = try store.load().examples
        XCTAssertEqual(loaded.map(\.id), ["mine-dup", "mine-dup", "mine-other"])
        XCTAssertEqual(Set(loaded.map(\.listID)).count, 3)

        try store.delete(loaded[1])
        let after = try store.load().examples
        XCTAssertEqual(after.first?.raw, "first take of the sentence")
        XCTAssertEqual(after.map(\.id), ["mine-dup", "mine-other"])
    }

    func testAStaleLinePositionIsRefusedAndNothingIsDeleted() throws {
        try store.append(example("mine-a"))
        try store.append(example("mine-b"))
        let second = try XCTUnwrap(try store.load().examples.last)
        try store.delete(try XCTUnwrap(try store.load().examples.first))
        // `second` now sits on line 0 but still says line 1.
        XCTAssertThrowsError(try store.delete(second))
        XCTAssertEqual(try store.load().examples.map(\.id), ["mine-b"])
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
        let exported = try PlaygroundExampleStore(fileURL: destination).load()
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
            XCTAssertTrue(reason.isExpected || sentence.contains("transcript") || sentence.contains("no text"), reason.rawValue)
            XCTAssertFalse(sentence.contains("_"), reason.rawValue)
        }
        XCTAssertTrue(PlaygroundFallbackText.sentence(forCode: "dropped").contains("changed your words"))
        XCTAssertTrue(PlaygroundFallbackText.sentence(forCode: "timeout").contains("too long"))
    }

    func testAnUnknownCodeStillGetsASentence() {
        XCTAssertTrue(PlaygroundFallbackText.sentence(forCode: "brand_new").contains("transcript"))
    }
}
