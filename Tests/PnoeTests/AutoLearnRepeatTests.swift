import XCTest

final class CorrectionCounterTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testThresholdIsReachedAtItsCount() {
        for threshold in AutoLearnRepeatThreshold.allCases {
            var counter = CorrectionCounter()
            for repeatNumber in 1...5 {
                let count = counter.record(heard: "pnoy", corrected: "Pnoe", now: start)
                XCTAssertEqual(count, repeatNumber)
                XCTAssertEqual(
                    threshold.isReached(by: count),
                    repeatNumber >= threshold.rawValue,
                    "threshold \(threshold.rawValue) after \(repeatNumber)"
                )
            }
        }
    }

    func testThresholdsRunFromImmediatelyToFive() {
        XCTAssertEqual(AutoLearnRepeatThreshold.allCases.map(\.rawValue), [1, 2, 3, 4, 5])
        XCTAssertEqual(AutoLearnRepeatThreshold.default, .twice)
        XCTAssertNil(AutoLearnRepeatThreshold(rawValue: 0))
        XCTAssertNil(AutoLearnRepeatThreshold(rawValue: 6))
    }

    func testHeardSideIsCaseInsensitiveCorrectedSideIsExact() {
        var counter = CorrectionCounter()
        XCTAssertEqual(counter.record(heard: "Pnoy", corrected: "Pnoe", now: start), 1)
        XCTAssertEqual(counter.record(heard: "pnoy", corrected: "Pnoe", now: start), 2)
        XCTAssertEqual(counter.record(heard: " PNOY ", corrected: "Pnoe", now: start), 3)
        XCTAssertEqual(counter.record(heard: "pnoy", corrected: "pnoe", now: start), 1)
        XCTAssertEqual(counter.pairs.count, 2)
    }

    func testDifferentCorrectionsOfOneHeardTextAreCountedApart() {
        var counter = CorrectionCounter()
        counter.record(heard: "there", corrected: "their", now: start)
        counter.record(heard: "there", corrected: "they're", now: start)
        XCTAssertEqual(counter.count(heard: "there", corrected: "their"), 1)
        XCTAssertEqual(counter.count(heard: "there", corrected: "they're"), 1)
    }

    func testResetForgetsThePair() {
        var counter = CorrectionCounter()
        counter.record(heard: "pnoy", corrected: "Pnoe", now: start)
        counter.record(heard: "pnoy", corrected: "Pnoe", now: start)
        counter.reset(heard: "PNOY", corrected: "Pnoe")
        XCTAssertEqual(counter.count(heard: "pnoy", corrected: "Pnoe"), 0)
        XCTAssertEqual(counter.record(heard: "pnoy", corrected: "Pnoe", now: start), 1)
    }

    func testStalePairStartsAgain() {
        let limits = CorrectionCounter.Limits(maximumPairs: 10, staleAfter: 100)
        var counter = CorrectionCounter()
        counter.record(heard: "pnoy", corrected: "Pnoe", now: start, limits: limits)
        let withinWindow = start.addingTimeInterval(100)
        XCTAssertEqual(counter.record(heard: "pnoy", corrected: "Pnoe", now: withinWindow, limits: limits), 2)
        let afterWindow = withinWindow.addingTimeInterval(101)
        XCTAssertEqual(counter.record(heard: "pnoy", corrected: "Pnoe", now: afterWindow, limits: limits), 1)
    }

    func testPruneDropsOnlyStalePairs() {
        let limits = CorrectionCounter.Limits(maximumPairs: 10, staleAfter: 100)
        var counter = CorrectionCounter()
        counter.record(heard: "old", corrected: "Old", now: start, limits: limits)
        counter.record(heard: "new", corrected: "New", now: start.addingTimeInterval(90), limits: limits)
        counter.prune(now: start.addingTimeInterval(150), limits: limits)
        XCTAssertEqual(counter.count(heard: "old", corrected: "Old"), 0)
        XCTAssertEqual(counter.count(heard: "new", corrected: "New"), 1)
    }

    func testCapKeepsTheMostRecentPairs() {
        let limits = CorrectionCounter.Limits(maximumPairs: 3, staleAfter: 1_000_000)
        var counter = CorrectionCounter()
        for index in 0..<5 {
            counter.record(
                heard: "word\(index)",
                corrected: "Word\(index)",
                now: start.addingTimeInterval(TimeInterval(index)),
                limits: limits
            )
        }
        XCTAssertEqual(counter.pairs.count, 3)
        XCTAssertEqual(counter.count(heard: "word0", corrected: "Word0"), 0)
        XCTAssertEqual(counter.count(heard: "word1", corrected: "Word1"), 0)
        XCTAssertEqual(counter.count(heard: "word4", corrected: "Word4"), 1)
    }

    func testStandardLimits() {
        XCTAssertEqual(CorrectionCounter.Limits.standard.maximumPairs, 200)
        XCTAssertEqual(CorrectionCounter.Limits.standard.staleAfter, 30 * 24 * 60 * 60)
    }
}

final class CorrectionCountStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("counts.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pnoe-count-store-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCountsSurviveARestart() async throws {
        let first = CorrectionCountStore(fileURL: fileURL)
        _ = try await first.record(heard: "pnoy", corrected: "Pnoe")
        _ = try await first.record(heard: "Pnoy", corrected: "Pnoe")

        let restarted = CorrectionCountStore(fileURL: fileURL)
        let count = await restarted.count(heard: "pnoy", corrected: "Pnoe")
        XCTAssertEqual(count, 2)
        let next = try await restarted.record(heard: "pnoy", corrected: "Pnoe")
        XCTAssertEqual(next, 3)
    }

    func testResetIsSavedAndUndoStartsAgain() async throws {
        let store = CorrectionCountStore(fileURL: fileURL)
        _ = try await store.record(heard: "pnoy", corrected: "Pnoe")
        _ = try await store.record(heard: "pnoy", corrected: "Pnoe")
        try await store.reset(heard: "pnoy", corrected: "Pnoe")

        let restarted = CorrectionCountStore(fileURL: fileURL)
        let count = await restarted.count(heard: "pnoy", corrected: "Pnoe")
        XCTAssertEqual(count, 0)
        let next = try await restarted.record(heard: "pnoy", corrected: "Pnoe")
        XCTAssertEqual(next, 1)
    }

    func testStaleCountsExpireAcrossARestart() async throws {
        let limits = CorrectionCounter.Limits(maximumPairs: 10, staleAfter: 60)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = CorrectionCountStore(fileURL: fileURL, limits: limits)
        _ = try await first.record(heard: "pnoy", corrected: "Pnoe", now: start)

        let restarted = CorrectionCountStore(fileURL: fileURL, limits: limits)
        let next = try await restarted.record(
            heard: "pnoy",
            corrected: "Pnoe",
            now: start.addingTimeInterval(61)
        )
        XCTAssertEqual(next, 1)
    }

    func testUnreadableFileStartsFresh() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        let store = CorrectionCountStore(fileURL: fileURL)
        let count = try await store.record(heard: "pnoy", corrected: "Pnoe")
        XCTAssertEqual(count, 1)
    }
}

final class CorrectionNoiseFilterTests: XCTestCase {
    private func learnable(_ heard: String, _ corrected: String, in pasted: String = "send it to the team today") -> Bool {
        CorrectionNoiseFilter.isLearnable(heard: heard, corrected: corrected, pastedText: pasted)
    }

    func testKeepsAWordAndAShortPhrase() {
        XCTAssertTrue(learnable("pnoy", "Pnoe"))
        XCTAssertTrue(learnable("open a i", "OpenAI"))
        XCTAssertTrue(learnable("cafe", "café"))
        XCTAssertTrue(learnable("it is", "it's is"))
    }

    func testIgnoresCaseOnlyChanges() {
        XCTAssertFalse(learnable("iphone", "iPhone"))
        XCTAssertFalse(learnable("Hello", "hello"))
    }

    func testIgnoresPunctuationOnlyChanges() {
        XCTAssertFalse(learnable("hello", "hello,"))
        XCTAssertFalse(learnable("well well", "well, well"))
        XCTAssertFalse(learnable("U.S.A", "USA"))
    }

    func testIgnoresPairsLongerThanAFewWords() {
        XCTAssertTrue(learnable("one two three four", "1 2 3 4"))
        XCTAssertFalse(learnable("one two three four five", "5"))
        XCTAssertFalse(learnable("a", "one two three four five"))
        XCTAssertFalse(learnable(String(repeating: "x", count: 49), "y"))
    }

    func testIgnoresMultiSentenceText() {
        XCTAssertFalse(learnable("fix this. then that", "done"))
        XCTAssertFalse(learnable("ok", "ok? yes"))
    }

    func testIgnoresRewritingTheWholePastedText() {
        XCTAssertFalse(learnable("send it today", "ship it later", in: "Send it today."))
        // One or two words replaced in a one or two word dictation is still a correction.
        XCTAssertTrue(learnable("pnoy", "Pnoe", in: "pnoy"))
        XCTAssertTrue(learnable("hey pnoy", "hi pnoe", in: "Hey, pnoy"))
    }

    func testIgnoresEmptyAndMultilinePairs() {
        XCTAssertFalse(learnable("", "x"))
        XCTAssertFalse(learnable("x", "   "))
        XCTAssertFalse(learnable("a\nb", "c"))
    }
}

final class AutoLearnFieldGuardTests: XCTestCase {
    func testOnlyPasswordFieldsAreSecure() {
        XCTAssertTrue(AutoLearnFieldGuard.isSecure(subrole: "AXSecureTextField"))
        XCTAssertFalse(AutoLearnFieldGuard.isSecure(subrole: "AXSearchField"))
        XCTAssertFalse(AutoLearnFieldGuard.isSecure(subrole: nil))
    }
}
