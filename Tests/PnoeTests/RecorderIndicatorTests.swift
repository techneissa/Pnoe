import AppKit
import XCTest

/// Headless checks for the recording indicator's logic: display choice, notch fallback, live
/// transcript tail, update throttling and what the live line shows. No window is created.
final class RecorderIndicatorTests: XCTestCase {
    private let builtInNotch = RecorderDisplayInfo(id: 1, name: "Built-in Display", isBuiltIn: true, hasNotch: true)
    private let builtInPlain = RecorderDisplayInfo(id: 1, name: "Built-in Display", isBuiltIn: true, hasNotch: false)
    private let studio = RecorderDisplayInfo(id: 2, name: "Studio Display", isBuiltIn: false, hasNotch: false)
    private let tv = RecorderDisplayInfo(id: 3, name: "LG TV", isBuiltIn: false, hasNotch: false)

    // MARK: - Display choice

    func testActiveSelectionFollowsFocusedWindowDisplay() {
        let id = RecorderDisplayPlanner.resolveDisplayID(
            selection: .active, displays: [builtInNotch, studio], activeID: 2, underMouseID: 1)
        XCTAssertEqual(id, 2)
    }

    func testActiveSelectionFallsBackToMouseThenFirstDisplay() {
        let displays = [builtInNotch, studio]
        XCTAssertEqual(
            RecorderDisplayPlanner.resolveDisplayID(
                selection: .active, displays: displays, activeID: nil, underMouseID: 2),
            2)
        XCTAssertEqual(
            RecorderDisplayPlanner.resolveDisplayID(
                selection: .active, displays: displays, activeID: nil, underMouseID: nil),
            1)
        // An id that is no longer connected counts as missing.
        XCTAssertEqual(
            RecorderDisplayPlanner.resolveDisplayID(
                selection: .active, displays: displays, activeID: 99, underMouseID: 98),
            1)
    }

    func testMainSelectionIgnoresFocusAndUsesMenuBarDisplay() {
        let id = RecorderDisplayPlanner.resolveDisplayID(
            selection: .main, displays: [builtInNotch, studio], activeID: 2, underMouseID: 2)
        XCTAssertEqual(id, 1)
    }

    func testNamedSelectionPicksThatDisplay() {
        let id = RecorderDisplayPlanner.resolveDisplayID(
            selection: .named("LG TV"), displays: [builtInNotch, studio, tv], activeID: 1, underMouseID: 1)
        XCTAssertEqual(id, 3)
    }

    func testNamedSelectionFallsBackToActiveWhenDisconnected() {
        let id = RecorderDisplayPlanner.resolveDisplayID(
            selection: .named("LG TV"), displays: [builtInNotch, studio], activeID: 2, underMouseID: 1)
        XCTAssertEqual(id, 2)
    }

    func testNoDisplaysGivesNoDisplay() {
        for selection in [RecorderDisplaySelection.active, .main, .named("LG TV")] {
            XCTAssertNil(
                RecorderDisplayPlanner.resolveDisplayID(
                    selection: selection, displays: [], activeID: 1, underMouseID: 1))
        }
    }

    func testDisplaySelectionStoredValueRoundTrips() {
        for selection in [RecorderDisplaySelection.active, .main, .named("Studio Display"), .named("A: b")] {
            XCTAssertEqual(RecorderDisplaySelection(storedValue: selection.storedValue), selection)
        }
        XCTAssertEqual(RecorderDisplaySelection(storedValue: nil), .active)
        XCTAssertEqual(RecorderDisplaySelection(storedValue: "garbage"), .active)
        XCTAssertEqual(RecorderDisplaySelection(storedValue: "name:"), .active)
    }

    // MARK: - Notch fallback

    func testNotchFallsBackToMiniOnBuiltInDisplayWithoutNotch() {
        XCTAssertEqual(RecorderDisplayPlanner.effectiveStyle(requested: .notch, display: builtInPlain), .mini)
    }

    func testNotchStaysOnNotchedAndExternalDisplays() {
        XCTAssertEqual(RecorderDisplayPlanner.effectiveStyle(requested: .notch, display: builtInNotch), .notch)
        XCTAssertEqual(RecorderDisplayPlanner.effectiveStyle(requested: .notch, display: studio), .notch)
        XCTAssertEqual(RecorderDisplayPlanner.effectiveStyle(requested: .notch, display: nil), .notch)
    }

    func testMiniNeverChanges() {
        for display in [builtInNotch, builtInPlain, studio] {
            XCTAssertEqual(RecorderDisplayPlanner.effectiveStyle(requested: .mini, display: display), .mini)
        }
    }

    // MARK: - Settings

    func testSettingsReadFromDefaultsWithFallbacks() throws {
        let suite = "pnoe.indicator.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(RecorderIndicatorSettings(defaults: defaults), RecorderIndicatorSettings())

        defaults.set("name:Studio Display", forKey: RecorderDisplaySettingsKeys.display)
        defaults.set("top", forKey: RecorderDisplaySettingsKeys.miniPlacement)
        defaults.set("always", forKey: RecorderDisplaySettingsKeys.visibility)
        let settings = RecorderIndicatorSettings(defaults: defaults)
        XCTAssertEqual(settings.display, .named("Studio Display"))
        XCTAssertEqual(settings.miniPlacement, .top)
        XCTAssertEqual(settings.visibility, .always)

        defaults.set("sideways", forKey: RecorderDisplaySettingsKeys.miniPlacement)
        defaults.set("never", forKey: RecorderDisplaySettingsKeys.visibility)
        let invalid = RecorderIndicatorSettings(defaults: defaults)
        XCTAssertEqual(invalid.miniPlacement, .bottom)
        XCTAssertEqual(invalid.visibility, .whileRecording)
    }

    func testDefaultsKeepTodaysBehaviour() {
        XCTAssertEqual(RecorderIndicatorSettings().visibility, .whileRecording)
        XCTAssertEqual(RecorderIndicatorSettings().miniPlacement, .bottom)
        XCTAssertEqual(RecorderIndicatorSettings().display, .active)
        XCTAssertEqual(LiveTranscriptSize.medium.fontSize, 12)
    }

    // MARK: - Live line content and visibility

    func testLiveLineShowsTextOnlyWhileRecording() {
        func content(_ state: RecordingState, _ partial: String, expects: Bool = true, enabled: Bool = true)
            -> LiveTranscriptContent?
        {
            LiveTranscriptContent.resolve(enabled: enabled, state: state, partial: partial, expectsPartials: expects)
        }

        XCTAssertEqual(content(.recording, "hello there"), .text("hello there"))
        XCTAssertNil(content(.transcribing, "hello there"))
        XCTAssertNil(content(.enhancing, "hello there"))
        XCTAssertNil(content(.idle, "hello there"))
        XCTAssertNil(content(.recording, "hello there", enabled: false))
    }

    func testStreamingEnginesShowListeningUntilFirstWordsAndOthersShowNothing() {
        XCTAssertEqual(
            LiveTranscriptContent.resolve(enabled: true, state: .recording, partial: "", expectsPartials: true),
            .listening)
        XCTAssertEqual(
            LiveTranscriptContent.resolve(enabled: true, state: .recording, partial: "  \n", expectsPartials: true),
            .listening)
        XCTAssertNil(
            LiveTranscriptContent.resolve(enabled: true, state: .recording, partial: "", expectsPartials: false))
    }

    // MARK: - Tail truncation

    private func lineCount(_ text: String, fontSize: CGFloat, width: CGFloat) -> Int {
        let font = NSFont.systemFont(ofSize: fontSize)
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lineHeight = font.ascender - font.descender + font.leading
        return Int((rect.height / lineHeight).rounded())
    }

    func testShortTextIsUnchanged() {
        XCTAssertEqual(LiveTranscriptFormatter.tail("hello there", fontSize: 12, width: 300), "hello there")
        XCTAssertEqual(LiveTranscriptFormatter.tail("  hello  ", fontSize: 12, width: 300), "hello")
        XCTAssertEqual(LiveTranscriptFormatter.tail("", fontSize: 12, width: 300), "")
    }

    func testLongTextKeepsNewestWordsInTwoLines() {
        let words = (1...80).map { "word\($0)" }
        let text = words.joined(separator: " ")
        for size in LiveTranscriptSize.allCases {
            let result = LiveTranscriptFormatter.tail(text, fontSize: size.fontSize, width: 300)
            XCTAssertTrue(result.hasPrefix(LiveTranscriptFormatter.ellipsis), "\(size)")
            XCTAssertTrue(result.hasSuffix("word80"), "\(size)")
            XCTAssertLessThanOrEqual(lineCount(result, fontSize: size.fontSize, width: 300), 2, "\(size)")
            // Only whole words remain, in order.
            let kept = result.dropFirst().split(separator: " ").map(String.init)
            XCTAssertEqual(kept, Array(words.suffix(kept.count)), "\(size)")
            XCTAssertGreaterThan(kept.count, 3, "\(size)")
        }
    }

    func testLargerTextKeepsFewerWords() {
        let text = (1...80).map { "word\($0)" }.joined(separator: " ")
        let small = LiveTranscriptFormatter.tail(text, fontSize: LiveTranscriptSize.small.fontSize, width: 300)
        let large = LiveTranscriptFormatter.tail(text, fontSize: LiveTranscriptSize.large.fontSize, width: 300)
        XCTAssertGreaterThan(small.count, large.count)
    }

    func testTextThatFitsKeepsItsStartAndGetsNoEllipsis() {
        let text = "one two three four five six seven eight nine ten"
        let result = LiveTranscriptFormatter.tail(text, fontSize: 12, width: 300)
        XCTAssertEqual(result, text)
    }

    func testVeryLongTextAndSingleLongWordStayBounded() {
        let huge = String(repeating: "alpha beta gamma ", count: 4000)
        let result = LiveTranscriptFormatter.tail(huge, fontSize: 12, width: 300)
        XCTAssertLessThan(result.count, 200)
        XCTAssertTrue(result.hasSuffix("gamma"))

        let word = String(repeating: "x", count: 600)
        XCTAssertFalse(LiveTranscriptFormatter.tail("start " + word, fontSize: 12, width: 300).isEmpty)
    }

    // MARK: - Throttle

    func testFirstPartialPublishesAtOnce() {
        var throttle = PartialTranscriptThrottle(interval: 0.1)
        XCTAssertEqual(throttle.submit("a", now: 10), .publish("a"))
    }

    func testBurstIsCoalescedIntoOneScheduledFlushWithNewestText() {
        var throttle = PartialTranscriptThrottle(interval: 0.1)
        XCTAssertEqual(throttle.submit("a", now: 10), .publish("a"))
        XCTAssertEqual(throttle.submit("ab", now: 10.02), .schedule(at: 10.1))
        XCTAssertEqual(throttle.submit("abc", now: 10.04), .hold)
        XCTAssertEqual(throttle.submit("abcd", now: 10.06), .hold)
        XCTAssertEqual(throttle.flush(now: 10.1), "abcd")
        XCTAssertNil(throttle.flush(now: 10.2))
    }

    func testPartialAfterIntervalPublishesAtOnce() {
        var throttle = PartialTranscriptThrottle(interval: 0.1)
        _ = throttle.submit("a", now: 10)
        XCTAssertEqual(throttle.submit("ab", now: 10.2), .publish("ab"))
    }

    func testFlushStartsNewIntervalAndResetClearsHeldText() {
        var throttle = PartialTranscriptThrottle(interval: 0.1)
        _ = throttle.submit("a", now: 10)
        _ = throttle.submit("ab", now: 10.05)
        XCTAssertEqual(throttle.flush(now: 10.1), "ab")
        XCTAssertEqual(throttle.submit("abc", now: 10.12), .schedule(at: 10.2))

        throttle.reset()
        XCTAssertNil(throttle.flush(now: 10.3))
        XCTAssertEqual(throttle.submit("x", now: 10.31), .publish("x"))
    }

    @MainActor
    func testRelayPublishesFirstAndLastOfABurstOnly() async throws {
        var published: [String] = []
        let relay = PartialTranscriptRelay(interval: 0.05) { published.append($0) }

        for text in ["a", "ab", "abc", "abcd"] { relay.submit(text) }
        XCTAssertEqual(published, ["a"])

        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(published, ["a", "abcd"])
    }

    @MainActor
    func testRelayResetDropsHeldText() async throws {
        var published: [String] = []
        let relay = PartialTranscriptRelay(interval: 0.05) { published.append($0) }

        relay.submit("a")
        relay.submit("ab")
        relay.reset()

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(published, ["a"])
    }
}
