import FormatterCore
import Foundation
import Testing
@testable import FormatterEvalKit

@Suite("Test set")
struct TestSetTests {
    let cases = Fixtures.cases

    @Test func hasAboutFourHundredTwentyCases() {
        #expect(cases.count == 420)
        #expect(Set(cases.map(\.id)).count == cases.count)
    }

    @Test func roundOneCasesEnterVerbatim() throws {
        let data = try Data(contentsOf: Fixtures.data.directory.appending(path: "round1/testset.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var original = try #require(json["cases"] as? [[String: Any]])
        let perf = try #require(json["perf"] as? [String: [String: Any]])
        original += [perf["perf50"]!, perf["perf200"]!]
        #expect(original.count == 38)
        for item in original {
            let id = "r1-" + (item["id"] as! String)
            let match = try #require(cases.first { $0.id == id }, "missing \(id)")
            #expect(match.raw == item["raw"] as? String)
            #expect(match.expected == item["expected"] as? String)
            #expect(match.context.rawValue == item["context"] as? String)
            #expect(match.seed == item["id"] as? String)
        }
    }

    @Test func failedRoundOneCasesAreFlagged() {
        let flagged = cases.filter { $0.tags.contains("flagged") }
        #expect(flagged.count == 32)
        #expect(flagged.allSatisfy { $0.id.hasPrefix("r1-") })
    }

    @Test func contextMixFollowsThePlan() {
        let byContext = Dictionary(grouping: cases, by: \.context).mapValues(\.count)
        #expect(byContext[.agent, default: 0] >= 130)
        #expect(byContext[.email, default: 0] >= 70)
        #expect(byContext[.chat, default: 0] >= 70)
        #expect(byContext[.notes, default: 0] >= 70)
        #expect(byContext[.plain, default: 0] >= 10)
    }

    @Test func agentCategoriesAreCovered() {
        let agent = cases.filter { $0.context == .agent && $0.id.hasPrefix("gen-") }
        func count(_ tag: String) -> Int { agent.filter { $0.tags.contains(tag) }.count }
        #expect(count("paths") >= 36)
        #expect(count("identifiers") >= 28)
        #expect(count("file-names") >= 18)
        #expect(count("injection") == 18)
        #expect(count("can-you") + count("statement-you") == 18)
    }

    @Test func alreadyCleanAndShortCasesHaveTheirQuota() {
        #expect(cases.filter { $0.kind == .cleanUnchanged }.count == 40)
        #expect(cases.filter { $0.kind == .shortSkip }.count == 20)
        for testCase in cases where testCase.kind == .cleanUnchanged { #expect(testCase.raw == testCase.expected) }
        for testCase in cases where testCase.kind == .shortSkip { #expect(SkipRule.wordCount(testCase.raw) < 4 || testCase.protectedSpans.count == 1) }
    }

    @Test func everyFailureCategoryHasCases() {
        func count(_ tag: String) -> Int { cases.filter { $0.tags.contains(tag) }.count }
        #expect(count("cat:dropped") >= 100)
        #expect(count("cat:selfcorr") >= 30)
        #expect(count("cat:rewrite") >= 60)
        #expect(count("cat:path") >= 60)
        #expect(count("cat:currency") >= 10)
        #expect(count("cat:inject") >= 15)
    }

    @Test func aThirdOfTheGeneratedRawsAreWhisperStyle() {
        let generated = cases.filter { $0.id.hasPrefix("gen-") }
        let whisper = generated.filter { $0.tags.contains("whisper") }.count
        #expect(whisper >= generated.count / 6)
    }

    @Test func protectedSpansAppearInTheExpectedText() {
        for testCase in cases {
            for span in testCase.protectedSpans {
                #expect(testCase.expected.contains(span), "\(testCase.id) lacks \(span)")
            }
        }
    }

    @Test func mustNotNeverContradictsTheExpectedText() {
        for testCase in cases where testCase.id.hasPrefix("gen-") {
            let padded = " " + testCase.expected.lowercased() + " "
            for banned in testCase.mustNot {
                #expect(!padded.contains(banned.lowercased()), "\(testCase.id) bans \(banned)")
            }
        }
    }

    @Test func everythingIsSynthetic() throws {
        // Addresses use reserved or round 1 example domains only, and no real-looking paths or numbers appear.
        let allowed: Set<String> = ["example.com", "example.org", "gmail.com"]
        let email = try Regex(#"[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})"#)
        for testCase in cases {
            for text in [testCase.raw, testCase.expected] {
                for match in text.matches(of: email) {
                    let domain = try #require(match.output[1].substring).lowercased()
                    #expect(allowed.contains(domain), "\(testCase.id): \(domain)")
                }
            }
            #expect(!testCase.raw.contains("/Users/"))
            #expect(!testCase.expected.contains("/Users/"))
        }
        let names = Set(["Maya", "Alex", "Priya", "Daniel", "Lena", "Tom", "Dana", "Sam", "Jo", "Marcus"])
        #expect(cases.contains { $0.raw.contains(names.first!) })
    }

    @Test func rawsAreUnique() {
        let keys = cases.map { "\($0.context.rawValue)|\($0.raw)" }
        #expect(Set(keys).count == keys.count)
    }

    @Test func malformedLinesAreReported() {
        #expect(throws: TestSet.LoadError.self) { try TestSet.parse("{\"id\": 3}\n") }
        let line = #"{"id":"a","context":"chat","raw":"x","expected":"X"}"#
        #expect(throws: TestSet.LoadError.self) { try TestSet.parse(line + "\n" + line) }
    }

    @Test func missingOptionalFieldsDefault() throws {
        let parsed = try TestSet.parse(#"{"id":"a","context":"chat","raw":"x y","expected":"X y"}"#)
        #expect(parsed[0].kind == .format)
        #expect(parsed[0].protectedSpans.isEmpty)
        #expect(parsed[0].mustContain.isEmpty)
    }

    @Test func dataDirectoryIsFoundFromTheWorkingTree() throws {
        let located = try EvalData.locate(explicit: Fixtures.data.directory.path)
        #expect(FileManager.default.fileExists(atPath: located.testsetURL.path))
        #expect(throws: EvalData.LocateError.self) { try EvalData.locate(explicit: "/nonexistent-eval-dir") }
    }
}
