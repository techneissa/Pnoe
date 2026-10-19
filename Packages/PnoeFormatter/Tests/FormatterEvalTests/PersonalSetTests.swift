import FormatterCore
import Foundation
import Testing
@testable import FormatterEvalKit

@Suite("Personal test set")
struct PersonalSetTests {
    /// A line the way the app's Workflow playground writes it, with its extra keys.
    static func line(
        id: String, raw: String = "um open the file on thursday", expected: String = "Open the file on Thursday.",
        tags: [String] = ["personal", "workflow:cleanedText"]
    ) -> String {
        let tagText = tags.map { "\"\($0)\"" }.joined(separator: ",")
        return """
            {"context":"plain","created":"2026-10-20T09:00:00Z","expected":"\(expected)","id":"\(id)","kind":"format","must_contain":[],"must_not":[],"output":"Open the file on Thursday.","protected":[],"raw":"\(raw)","tags":[\(tagText)],"workflow":"Cleaned Text"}
            """
    }

    @Test func readsTheAppsLinesAsCases() {
        let set = PersonalSet.parse(Self.line(id: "mine-aa") + "\n" + Self.line(id: "mine-bb") + "\n")
        #expect(set.cases.map(\.id) == ["mine-aa", "mine-bb"])
        #expect(set.cases[0].context == .plain)
        #expect(set.cases[0].raw == "um open the file on thursday")
        #expect(set.cases[0].expected == "Open the file on Thursday.")
        #expect(set.cases[0].kind == .format)
        #expect(set.unreadableLines == 0)
    }

    @Test func skipsUnreadableLinesAndCountsThem() {
        let text = [Self.line(id: "mine-aa"), "not json at all", "{\"id\":\"x\"}", Self.line(id: "mine-bb")].joined(separator: "\n")
        let set = PersonalSet.parse(text)
        #expect(set.cases.map(\.id) == ["mine-aa", "mine-bb"])
        #expect(set.unreadableLines == 2)
    }

    @Test func aRepeatedIdCountsAsUnreadable() {
        let set = PersonalSet.parse(Self.line(id: "mine-aa") + "\n" + Self.line(id: "mine-aa"))
        #expect(set.cases.count == 1)
        #expect(set.unreadableLines == 1)
    }

    @Test func leavesOutPairsFromOtherWorkflows() {
        let text = [
            Self.line(id: "mine-aa"),
            Self.line(id: "mine-bb", tags: ["personal", "workflow:summary"]),
            Self.line(id: "mine-cc", tags: ["personal", "workflow:custom"]),
            Self.line(id: "mine-dd", tags: ["personal"]),
        ].joined(separator: "\n")
        let set = PersonalSet.parse(text)
        #expect(set.cases.map(\.id) == ["mine-aa", "mine-dd"])
        #expect(set.skippedOtherWorkflows == 2)
    }

    @Test func anEmptyFileGivesNoCases() {
        let set = PersonalSet.parse("")
        #expect(set.cases.isEmpty)
        #expect(set.unreadableLines == 0)
    }

    @Test func loadsAFileFromDisk() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "personal-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try (Self.line(id: "mine-aa") + "\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(try PersonalSet.load(from: url).cases.map(\.id) == ["mine-aa"])
    }

    @Test func aMissingFileThrows() {
        let url = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID().uuidString).jsonl")
        #expect(throws: (any Error).self) { try PersonalSet.load(from: url) }
    }

    @Test func mergeAppendsAfterTheBuiltInSet() throws {
        let personal = PersonalSet.parse(Self.line(id: "mine-aa")).cases
        let merged = try PersonalSet.merge(Fixtures.cases, with: personal)
        #expect(merged.count == Fixtures.cases.count + 1)
        #expect(merged.last?.id == "mine-aa")
    }

    @Test func mergeRefusesAnIdTheBuiltInSetAlreadyHas() {
        let clash = PersonalSet.parse(Self.line(id: Fixtures.cases[0].id)).cases
        #expect(throws: TestSet.LoadError.self) { try PersonalSet.merge(Fixtures.cases, with: clash) }
    }
}
