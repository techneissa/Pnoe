import XCTest

private let rate = 16_000

private func segment(_ text: String, _ start: Double, _ end: Double) -> WhisperKitLiveSegment {
    WhisperKitLiveSegment(text: text, start: start, end: end)
}

private func result(_ segments: [WhisperKitLiveSegment], language: String? = "en") -> WhisperKitLiveResult {
    WhisperKitLiveResult(segments: segments, language: language)
}

private func speech(seconds: Double) -> [Float] {
    [Float](repeating: 0.1, count: Int(seconds * Double(rate)))
}

// MARK: - Planner

final class WhisperKitLivePlannerTests: XCTestCase {
    private func planner(language: String? = nil, prompt: String? = nil) -> WhisperKitLivePlanner {
        WhisperKitLivePlanner(language: language, prompt: prompt)
    }

    func testNoWindowBeforeOneSecondOfAudio() {
        let planner = planner()
        XCTAssertNil(planner.nextRequest(totalSamples: 0))
        XCTAssertNil(planner.nextRequest(totalSamples: rate - 1))
        let request = planner.nextRequest(totalSamples: rate)
        XCTAssertEqual(request?.windowStart, 0)
        XCTAssertEqual(request?.windowEnd, rate)
    }

    func testWindowsComeEveryHalfSecondOfNewAudio() {
        var planner = planner()
        var decodedAt: [Double] = []
        // Audio arrives in 0.25 s steps for 4 s.
        for step in 1...16 {
            let total = step * rate / 4
            if let request = planner.nextRequest(totalSamples: total) {
                decodedAt.append(Double(total) / Double(rate))
                _ = planner.apply(result([segment("a", 0, 1)]), to: request)
            }
        }
        XCTAssertEqual(decodedAt, [1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0])
    }

    func testAWindowThatWasNotDecodedIsAskedForAgain() {
        let planner = planner()
        let first = planner.nextRequest(totalSamples: rate)
        // Nothing applied (the engine dropped it): the same audio is still due.
        XCTAssertEqual(planner.nextRequest(totalSamples: rate), first)
    }

    func testSilentAudioIsSkippedAndWaitsForMore() {
        var planner = planner()
        let request = planner.nextRequest(totalSamples: rate)!
        planner.skip(request)
        XCTAssertNil(planner.nextRequest(totalSamples: rate + rate / 4))
        XCTAssertNotNil(planner.nextRequest(totalSamples: rate + rate / 2))
    }

    func testTheLiveTextIsTheWholeWindowAndRepeatsStayStable() {
        var planner = planner()
        var request = planner.nextRequest(totalSamples: rate)!
        XCTAssertEqual(planner.apply(result([segment(" hello", 0, 1)]), to: request), "hello")
        request = planner.nextRequest(totalSamples: 2 * rate)!
        let text = planner.apply(result([segment(" hello there", 0, 1), segment("general kenobi ", 1, 2)]), to: request)
        XCTAssertEqual(text, "hello there general kenobi")
        XCTAssertEqual(planner.windowStart, 0, "nothing is confirmed in a short window")
    }

    func testPastTwentySecondsAllButTheLastSegmentIsConfirmedAndTheWindowMoves() {
        var planner = planner()
        let total = 21 * rate
        let request = planner.nextRequest(totalSamples: total)!
        let text = planner.apply(
            result([segment("one.", 0, 8), segment("two.", 8, 15), segment("three", 15, 21)]), to: request)
        XCTAssertEqual(text, "one. two. three")
        XCTAssertEqual(planner.confirmedText, "one. two.")
        XCTAssertEqual(planner.windowStart, 15 * rate)

        // The next pass decodes from the end of the confirmed text and carries it as the prompt.
        let next = planner.nextRequest(totalSamples: total + rate)!
        XCTAssertEqual(next.windowStart, 15 * rate)
        XCTAssertEqual(next.prompt, "one. two.")
        let more = planner.apply(result([segment("three four", 0, 7)]), to: next)
        XCTAssertEqual(more, "one. two. three four")
    }

    func testAOneSegmentWindowIsKeptUntilTheHardLimitThenConfirmedWhole() {
        var planner = planner()
        var request = planner.nextRequest(totalSamples: 25 * rate)!
        _ = planner.apply(result([segment("long", 0, 25)]), to: request)
        XCTAssertEqual(planner.confirmedText, "", "one segment is still the hypothesis at 25 s")

        request = planner.nextRequest(totalSamples: 28 * rate)!
        let text = planner.apply(result([segment("long speech", 0, 28)]), to: request)
        XCTAssertEqual(text, "long speech")
        XCTAssertEqual(planner.confirmedText, "long speech")
        XCTAssertEqual(planner.windowStart, 28 * rate)
        XCTAssertNil(planner.nextRequest(totalSamples: 28 * rate + rate / 2), "a new window needs one second")
    }

    func testTheDetectedLanguageIsPinnedAfterTheFirstPass() {
        var planner = planner(language: nil)
        let first = planner.nextRequest(totalSamples: rate)!
        XCTAssertNil(first.language)
        _ = planner.apply(result([segment("bonjour", 0, 1)], language: "fr"), to: first)
        XCTAssertEqual(planner.nextRequest(totalSamples: 2 * rate)?.language, "fr")
    }

    func testAChosenLanguageIsNeverReplacedByTheDetectedOne() {
        var planner = planner(language: "de")
        let first = planner.nextRequest(totalSamples: rate)!
        _ = planner.apply(result([segment("hallo", 0, 1)], language: "en"), to: first)
        XCTAssertEqual(planner.nextRequest(totalSamples: 2 * rate)?.language, "de")
    }

    func testSilenceAndSoundTagsNeverReachTheLiveLine() {
        var planner = planner()
        let request = planner.nextRequest(totalSamples: rate)!
        let text = planner.apply(
            result([segment(" [BLANK_AUDIO]", 0, 1), segment("(music)", 1, 2), segment(" real words", 2, 3)]),
            to: request)
        XCTAssertEqual(text, "real words")
    }

    func testThePromptIsTheCustomWordsThenTheTailOfTheConfirmedText() {
        var settings = WhisperKitLivePlanner.Settings()
        settings.promptTailCharacters = 11
        var planner = WhisperKitLivePlanner(settings: settings, language: nil, prompt: " Pnoe ")
        XCTAssertEqual(planner.nextRequest(totalSamples: rate)?.prompt, "Pnoe")

        let request = planner.nextRequest(totalSamples: 21 * rate)!
        _ = planner.apply(
            result([segment("alpha beta gamma delta", 0, 10), segment("epsilon", 10, 21)]), to: request)
        XCTAssertEqual(planner.nextRequest(totalSamples: 22 * rate)?.prompt, "Pnoe gamma delta")
    }
}

// MARK: - Session

private final class FakeDecoder: WhisperKitLiveDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [WhisperKitLiveResult?]
    private(set) var calls: [(samples: Int, language: String?, prompt: String?)] = []
    private(set) var running = 0
    private(set) var maxRunning = 0
    private(set) var cancelled = 0
    private var held = false

    init(replies: [WhisperKitLiveResult?]) { self.replies = replies }

    /// While held, a decode waits (until released or cancelled).
    func hold(_ value: Bool) { lock.withLock { held = value } }
    var callCount: Int { lock.withLock { calls.count } }

    func decodeLive(samples: [Float], language: String?, prompt: String?) async throws -> WhisperKitLiveResult? {
        let reply: WhisperKitLiveResult? = lock.withLock {
            calls.append((samples.count, language, prompt))
            running += 1
            maxRunning = max(maxRunning, running)
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        defer { lock.withLock { running -= 1 } }
        while lock.withLock({ held }) {
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                lock.withLock { cancelled += 1 }
                throw error
            }
        }
        try Task.checkCancellation()
        return reply
    }
}

private final class Partials: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ text: String) { lock.withLock { values.append(text) } }
    var all: [String] { lock.withLock { values } }
}

final class WhisperKitLiveSessionTests: XCTestCase {
    private func waitUntil(_ message: String = "condition", _ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), message)
    }

    private func makeSession(
        _ decoder: FakeDecoder, partials: Partials, language: String? = "en", prompt: String? = nil,
        settings: WhisperKitLivePlanner.Settings = .init()
    ) -> WhisperKitLiveSession {
        WhisperKitLiveSession(
            decoder: decoder, language: language, prompt: prompt, settings: settings,
            onPartial: { partials.add($0) })
    }

    func testNothingIsDecodedBeforeEnoughAudioAndNothingTwiceForTheSameAudio() async {
        let decoder = FakeDecoder(replies: [result([segment("hi", 0, 1)])])
        let partials = Partials()
        let session = makeSession(decoder, partials: partials)

        await session.append(speech(seconds: 0.9))
        await session.tick()
        XCTAssertEqual(decoder.callCount, 0)

        await session.append(speech(seconds: 0.2))
        await session.tick()
        XCTAssertEqual(decoder.callCount, 1)
        XCTAssertEqual(decoder.calls[0].samples, Int(1.1 * Double(rate)))

        await session.tick()
        XCTAssertEqual(decoder.callCount, 1, "no new audio, no new pass")
        XCTAssertEqual(partials.all, ["hi"])
    }

    func testPartialsArePublishedInOrderAndRepeatsAreNotPublishedAgain() async {
        let decoder = FakeDecoder(replies: [
            result([segment("hello", 0, 1)]),
            result([segment("hello", 0, 1.5)]),
            result([segment("hello world", 0, 2)]),
            result([segment("hello world again", 0, 2.5)]),
        ])
        let partials = Partials()
        let session = makeSession(decoder, partials: partials)

        for _ in 0..<4 {
            await session.append(speech(seconds: 0.5))
            await session.append(speech(seconds: 0.5))
            await session.tick()
        }

        XCTAssertEqual(partials.all, ["hello", "hello world", "hello world again"])
    }

    func testATickWhilePreviousPassStillRunsIsDroppedAndNeverOverlaps() async throws {
        let decoder = FakeDecoder(replies: [result([segment("slow", 0, 1)]), result([segment("slow two", 0, 2)])])
        let partials = Partials()
        let session = makeSession(decoder, partials: partials)
        await session.append(speech(seconds: 1))
        decoder.hold(true)

        let first = Task { await session.tick() }
        try await waitUntil("pass started") { decoder.callCount == 1 }
        await session.append(speech(seconds: 1))
        await session.tick()
        await session.tick()
        XCTAssertEqual(decoder.callCount, 1, "ticks during a pass are dropped")
        XCTAssertEqual(decoder.maxRunning, 1)

        decoder.hold(false)
        await first.value
        XCTAssertEqual(partials.all, ["slow"])

        // The next tick decodes the newer audio.
        await session.tick()
        XCTAssertEqual(decoder.callCount, 2)
        XCTAssertEqual(decoder.calls[1].samples, 2 * rate)
        XCTAssertEqual(partials.all, ["slow", "slow two"])
        XCTAssertEqual(decoder.maxRunning, 1)
    }

    func testAWindowTheEngineDroppedIsTriedAgainOnTheNextTick() async {
        let decoder = FakeDecoder(replies: [nil, result([segment("back", 0, 1)])])
        let partials = Partials()
        let session = makeSession(decoder, partials: partials)
        await session.append(speech(seconds: 1))

        await session.tick()
        XCTAssertEqual(partials.all, [])
        await session.tick()
        XCTAssertEqual(decoder.callCount, 2)
        XCTAssertEqual(partials.all, ["back"])
    }

    func testSilentAudioNeverReachesTheDecoder() async {
        let decoder = FakeDecoder(replies: [result([segment("Thank you.", 0, 1)])])
        let partials = Partials()
        let session = makeSession(decoder, partials: partials)
        await session.append([Float](repeating: 0, count: 2 * rate))

        await session.tick()

        XCTAssertEqual(decoder.callCount, 0)
        XCTAssertEqual(partials.all, [])
    }

    func testTheLanguageAndPromptReachTheDecoderAndTheBufferIsTrimmedAfterAConfirmation() async {
        var settings = WhisperKitLivePlanner.Settings()
        settings.commitAfterSeconds = 2
        settings.maxWindowSeconds = 6
        let decoder = FakeDecoder(replies: [
            result([segment("first.", 0, 1.2), segment("second", 1.2, 2.5)]),
            result([segment("second part", 0, 2)]),
        ])
        let partials = Partials()
        let session = makeSession(decoder, partials: partials, language: "auto", prompt: "Pnoe", settings: settings)

        await session.append(speech(seconds: 3))
        await session.tick()
        XCTAssertEqual(decoder.calls[0].language, nil)
        XCTAssertEqual(decoder.calls[0].prompt, "Pnoe")
        XCTAssertEqual(partials.all, ["first. second"])

        // "first." is confirmed and ends at 1.2 s; the next window starts there and has the prompt.
        await session.append(speech(seconds: 1))
        await session.tick()
        XCTAssertEqual(decoder.calls[1].samples, Int(2.8 * Double(rate)))
        XCTAssertEqual(decoder.calls[1].language, "en")
        XCTAssertEqual(decoder.calls[1].prompt, "Pnoe first.")
        XCTAssertEqual(partials.all.last, "first. second part")
    }

    func testStopCancelsARunningPassAndNothingIsPublishedOrDecodedAfterIt() async throws {
        let decoder = FakeDecoder(replies: [result([segment("late", 0, 1)]), result([segment("later", 0, 2)])])
        let partials = Partials()
        let session = makeSession(decoder, partials: partials)
        await session.append(speech(seconds: 1))
        decoder.hold(true)

        let running = Task { await session.tick() }
        try await waitUntil("pass started") { decoder.callCount == 1 }
        await session.stop()
        await running.value

        XCTAssertEqual(decoder.cancelled, 1)
        XCTAssertEqual(decoder.running, 0)
        XCTAssertEqual(partials.all, [])

        decoder.hold(false)
        await session.append(speech(seconds: 2))
        await session.tick()
        XCTAssertEqual(decoder.callCount, 1)
        XCTAssertEqual(partials.all, [])
    }

    func testTheLoopTicksUntilStopAndThenStopsEverything() async throws {
        let decoder = FakeDecoder(replies: Array(repeating: result([segment("go", 0, 1)]), count: 50))
        let partials = Partials()
        let session = makeSession(decoder, partials: partials)
        await session.append(speech(seconds: 1))
        await session.start(interval: .milliseconds(10))
        try await waitUntil("a pass ran from the loop") { decoder.callCount >= 1 }

        // New audio keeps the loop deciding; stop ends it.
        await session.append(speech(seconds: 1))
        try await waitUntil("a second pass ran") { decoder.callCount >= 2 }
        await session.stop()
        let calls = decoder.callCount
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(decoder.callCount, calls, "no pass after stop")
        XCTAssertEqual(decoder.running, 0)
    }
}
