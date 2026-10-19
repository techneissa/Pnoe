import XCTest

final class WordDiffTests: XCTestCase {
    private func kinds(_ segments: [WordDiff.Segment], _ kind: WordDiff.Kind) -> [String] {
        segments.filter { $0.kind == kind }.map(\.word)
    }

    func testIdenticalTextHasNoChanges() {
        let segments = WordDiff.segments(from: "open the file", to: "Open the file.")
        XCTAssertFalse(WordDiff.hasChanges(segments))
        XCTAssertEqual(segments.map(\.word), ["Open", "the", "file."])
    }

    func testAddedAndMissingWordsAreMarkedInPlace() {
        let segments = WordDiff.segments(from: "send the file to Sam", to: "email the file to Sam today")
        XCTAssertEqual(kinds(segments, .added), ["email", "today"])
        XCTAssertEqual(kinds(segments, .missing), ["send"])
        XCTAssertEqual(segments.map(\.word), ["email", "send", "the", "file", "to", "Sam", "today"])
    }

    func testAChangedWordIsOneMissingAndOneAdded() {
        let segments = WordDiff.segments(from: "call Sam on friday", to: "call Sam on monday")
        XCTAssertEqual(kinds(segments, .missing), ["friday"])
        XCTAssertEqual(kinds(segments, .added), ["monday"])
    }

    func testCaseAndPunctuationDoNotCount() {
        XCTAssertFalse(WordDiff.hasChanges(WordDiff.segments(from: "Hello, world", to: "hello world!")))
    }

    func testEmptySides() {
        XCTAssertEqual(WordDiff.segments(from: "", to: "").count, 0)
        XCTAssertEqual(kinds(WordDiff.segments(from: "", to: "a b"), .added), ["a", "b"])
        XCTAssertEqual(kinds(WordDiff.segments(from: "a b", to: ""), .missing), ["a", "b"])
    }
}

final class EnhancementSkipPolicyTests: XCTestCase {
    func testThresholdFallsBackToThreeWhenNothingIsSaved() {
        XCTAssertEqual(EnhancementSkipPolicy.threshold(saved: 0), 3)
        XCTAssertEqual(EnhancementSkipPolicy.threshold(saved: -2), 3)
        XCTAssertEqual(EnhancementSkipPolicy.threshold(saved: 5), 5)
    }

    func testShortTakesAreSkippedOnlyWhenTheSettingIsOn() {
        XCTAssertTrue(skip(short: true, words: 3))
        XCTAssertFalse(skip(short: true, words: 4))
        XCTAssertFalse(skip(short: false, words: 1))
    }

    func testSnippetOnlyTakesAreSkipped() {
        XCTAssertTrue(skip(snippetsOnly: true, short: false, words: 40))
    }

    func testARecorderResponseAlwaysRunsTheModel() {
        XCTAssertFalse(skip(snippetsOnly: true, respond: true, short: true, words: 1))
    }

    private func skip(snippetsOnly: Bool = false, respond: Bool = false, short: Bool, words: Int) -> Bool {
        EnhancementSkipPolicy.shouldSkip(
            snippetsOnly: snippetsOnly, respondInRecorder: respond, skipShortEnabled: short, wordCount: words, threshold: 3)
    }
}
