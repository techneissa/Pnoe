import XCTest

/// Stands in for the WhisperKit package: records what the engine asks of it.
private final class FakeRunner: WhisperKitRunner, @unchecked Sendable {
    enum Mode { case instant, slow, blocksUntilCancelled }

    private let lock = NSLock()
    private(set) var loadedFolders: [URL] = []
    private(set) var tokenizerBases: [URL] = []
    private(set) var requests: [(audio: URL, language: String?, prompt: String?)] = []
    private(set) var unloadCount = 0
    private(set) var takesRunning = 0
    private(set) var maxTakesRunning = 0
    private(set) var takesRunningAtUnload: [Int] = []
    private(set) var cancelledTakes = 0
    private(set) var liveRequests: [(samples: Int, language: String?, prompt: String?)] = []
    private(set) var cancelledLives = 0
    var liveReply = WhisperKitLiveResult(
        segments: [WhisperKitLiveSegment(text: " live words", start: 0, end: 1)], language: "en")
    var reply = "  hello world \n"
    var failLoad = false
    var loadDelay: Duration = .zero
    var mode: Mode = .instant

    func load(modelFolder: URL, tokenizerBase: URL) async throws {
        lock.withLock {
            loadedFolders.append(modelFolder)
            tokenizerBases.append(tokenizerBase)
        }
        if loadDelay > .zero { try await Task.sleep(for: loadDelay) }
        if failLoad { throw CocoaError(.fileReadCorruptFile) }
    }

    func transcribe(audioURL: URL, language: String?, prompt: String?) async throws -> String {
        lock.withLock {
            requests.append((audioURL, language, prompt))
            takesRunning += 1
            maxTakesRunning = max(maxTakesRunning, takesRunning)
        }
        defer { lock.withLock { takesRunning -= 1 } }
        switch mode {
        case .instant:
            break
        case .slow:
            try await Task.sleep(for: .milliseconds(40))
        case .blocksUntilCancelled:
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                lock.withLock { cancelledTakes += 1 }
                throw error
            }
        }
        return reply
    }

    func transcribeLive(samples: [Float], language: String?, prompt: String?) async throws -> WhisperKitLiveResult {
        lock.withLock {
            liveRequests.append((samples.count, language, prompt))
            takesRunning += 1
            maxTakesRunning = max(maxTakesRunning, takesRunning)
        }
        defer { lock.withLock { takesRunning -= 1 } }
        if mode == .blocksUntilCancelled {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                lock.withLock { cancelledLives += 1 }
                throw error
            }
        }
        return liveReply
    }

    func unload() async {
        lock.withLock {
            unloadCount += 1
            takesRunningAtUnload.append(takesRunning)
        }
    }

    var startedTakes: Int { lock.withLock { requests.count } }
}

private final class RunnerBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var made: [FakeRunner] = []
    var failLoad = false
    var loadDelay: Duration = .zero
    var mode: FakeRunner.Mode = .instant

    func make() -> FakeRunner {
        let runner = FakeRunner()
        runner.failLoad = failLoad
        runner.loadDelay = loadDelay
        runner.mode = mode
        lock.withLock { made.append(runner) }
        return runner
    }
}

final class WhisperKitEngineTests: XCTestCase {
    private var root: URL!
    private var storage: WhisperKitStorage!
    private let audio = URL(fileURLWithPath: "/tmp/take.wav")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperKitEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        storage = WhisperKitStorage(base: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func installed(_ spec: WhisperKitModelSpec) throws -> WhisperKitModelSpec {
        // A test-sized copy of the real entry, so the filler file stays small.
        let small = WhisperKitModelSpec(
            name: spec.name, displayName: spec.displayName, description: spec.description,
            variant: spec.variant, modelBytes: 16, tokenizerRepository: spec.tokenizerRepository,
            tokenizerRevision: spec.tokenizerRevision, tokenizerBytes: 3,
            isMultilingual: spec.isMultilingual, speed: spec.speed, accuracy: spec.accuracy,
            ramUsage: spec.ramUsage)
        let folder = storage.modelFolder(for: small)
        for component in WhisperKitCatalog.requiredComponents {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent(component), withIntermediateDirectories: true)
        }
        try Data(count: 16).write(to: folder.appendingPathComponent("AudioEncoder.mlmodelc/w.bin"))
        let tokenizer = storage.tokenizerFolder(for: small)
        try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        for name in WhisperKitCatalog.tokenizerFiles {
            try Data(count: 1).write(to: tokenizer.appendingPathComponent(name))
        }
        try storage.markInstalled(small)
        return small
    }

    private func makeEngine(_ box: RunnerBox) -> WhisperKitEngine {
        WhisperKitEngine(storage: storage, makeRunner: { box.make() })
    }

    // MARK: Wiring

    func testTranscribeLoadsTheInstalledModelFromItsFolderAndTrimsTheText() async throws {
        let spec = try installed(WhisperKitCatalog.small)
        let box = RunnerBox()
        let engine = makeEngine(box)

        let text = try await engine.transcribe(audioURL: audio, spec: spec, language: "en", prompt: nil)

        XCTAssertEqual(text, "hello world")
        let runner = try XCTUnwrap(box.made.first)
        XCTAssertEqual(runner.loadedFolders, [storage.modelFolder(for: spec)])
        XCTAssertEqual(runner.tokenizerBases, [root])
        XCTAssertEqual(runner.requests.map(\.audio), [audio])
    }

    func testTheModelIsLoadedOnceForSeveralTakes() async throws {
        let spec = try installed(WhisperKitCatalog.small)
        let box = RunnerBox()
        let engine = makeEngine(box)

        for _ in 0..<3 {
            _ = try await engine.transcribe(audioURL: audio, spec: spec, language: nil, prompt: nil)
        }

        XCTAssertEqual(box.made.count, 1)
        XCTAssertEqual(box.made[0].loadedFolders.count, 1)
        XCTAssertEqual(box.made[0].requests.count, 3)
    }

    func testPreloadLoadsBeforeTheFirstTake() async throws {
        let spec = try installed(WhisperKitCatalog.small)
        let box = RunnerBox()
        let engine = makeEngine(box)

        try await engine.load(spec)
        XCTAssertEqual(box.made[0].loadedFolders.count, 1)
        XCTAssertTrue(box.made[0].requests.isEmpty)

        _ = try await engine.transcribe(audioURL: audio, spec: spec, language: nil, prompt: nil)
        XCTAssertEqual(box.made.count, 1)
    }

    func testSwitchingModelsUnloadsTheOldOneFirst() async throws {
        let small = try installed(WhisperKitCatalog.small)
        let base = try installed(WhisperKitCatalog.base)
        let box = RunnerBox()
        let engine = makeEngine(box)

        _ = try await engine.transcribe(audioURL: audio, spec: small, language: nil, prompt: nil)
        _ = try await engine.transcribe(audioURL: audio, spec: base, language: nil, prompt: nil)

        XCTAssertEqual(box.made.count, 2)
        XCTAssertEqual(box.made[0].unloadCount, 1)
        XCTAssertEqual(box.made[1].loadedFolders, [storage.modelFolder(for: base)])
    }

    func testUnloadFreesTheModelAndTheNextTakeReloads() async throws {
        let spec = try installed(WhisperKitCatalog.small)
        let box = RunnerBox()
        let engine = makeEngine(box)

        _ = try await engine.transcribe(audioURL: audio, spec: spec, language: nil, prompt: nil)
        await engine.unload()
        _ = try await engine.transcribe(audioURL: audio, spec: spec, language: nil, prompt: nil)

        XCTAssertEqual(box.made.count, 2)
        XCTAssertEqual(box.made[0].unloadCount, 1)
    }

    func testAModelThatIsNotDownloadedFailsWithoutStartingWhisperKit() async {
        let box = RunnerBox()
        let engine = makeEngine(box)

        do {
            _ = try await engine.transcribe(
                audioURL: audio, spec: WhisperKitCatalog.small, language: nil, prompt: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(
                error as? WhisperKitEngineError, .modelNotInstalled(WhisperKitCatalog.small.displayName))
        }
        XCTAssertTrue(box.made.isEmpty)
    }

    func testALoadFailureLeavesNothingLoaded() async throws {
        let spec = try installed(WhisperKitCatalog.small)
        let box = RunnerBox()
        box.failLoad = true
        let engine = makeEngine(box)

        do {
            _ = try await engine.transcribe(audioURL: audio, spec: spec, language: nil, prompt: nil)
            XCTFail("expected an error")
        } catch {}

        box.failLoad = false
        _ = try await engine.transcribe(audioURL: audio, spec: spec, language: nil, prompt: nil)
        XCTAssertEqual(box.made.count, 2)
        XCTAssertEqual(box.made[1].requests.count, 1)
    }

    // MARK: Language and prompt

    func testLanguageCodes() {
        XCTAssertNil(WhisperKitEngine.languageCode(from: nil))
        XCTAssertNil(WhisperKitEngine.languageCode(from: "auto"))
        XCTAssertNil(WhisperKitEngine.languageCode(from: " "))
        XCTAssertEqual(WhisperKitEngine.languageCode(from: "en"), "en")
        XCTAssertEqual(WhisperKitEngine.languageCode(from: "DE"), "de")
        XCTAssertEqual(WhisperKitEngine.languageCode(from: "en-US"), "en")
    }

    func testTheRunnerGetsTheBareLanguageAndTheTrimmedPrompt() async throws {
        let spec = try installed(WhisperKitCatalog.small)
        let box = RunnerBox()
        let engine = makeEngine(box)

        _ = try await engine.transcribe(audioURL: audio, spec: spec, language: "fr-CA", prompt: "  Pnoe, Argmax \n")
        _ = try await engine.transcribe(audioURL: audio, spec: spec, language: "auto", prompt: "   ")

        let requests = box.made[0].requests
        XCTAssertEqual(requests[0].language, "fr")
        XCTAssertEqual(requests[0].prompt, "Pnoe, Argmax")
        XCTAssertNil(requests[1].language)
        XCTAssertNil(requests[1].prompt)
    }

    // MARK: Concurrency

    /// Waits until `condition` holds, so a test does not depend on scheduling.
    private func waitUntil(_ message: String = "condition", _ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), message)
    }

    func testAPreloadAndTheFirstTakeShareOneLoad() async throws {
        let spec = try installed(WhisperKitCatalog.small)
        let box = RunnerBox()
        box.loadDelay = .milliseconds(80)
        let engine = makeEngine(box)

        async let preload: Void = engine.load(spec)
        async let take = engine.transcribe(audioURL: audio, spec: spec, language: nil, prompt: nil)
        _ = try await (preload, take)

        XCTAssertEqual(box.made.count, 1)
        XCTAssertEqual(box.made[0].loadedFolders.count, 1)
        XCTAssertEqual(box.made[0].requests.count, 1)
    }

    func testManyConcurrentLoadsLoadOnce() async throws {
        let spec = try installed(WhisperKitCatalog.small)
        let box = RunnerBox()
        box.loadDelay = .milliseconds(50)
        let engine = makeEngine(box)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 { group.addTask { try await engine.load(spec) } }
            try await group.waitForAll()
        }

        XCTAssertEqual(box.made.count, 1)
        XCTAssertEqual(box.made[0].loadedFolders.count, 1)
    }

    func testTakesRunOneAtATimeInTheOrderAsked() async throws {
        let spec = try installed(WhisperKitCatalog.small)
        let box = RunnerBox()
        box.mode = .slow
        let engine = makeEngine(box)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<4 {
                group.addTask {
                    _ = try await engine.transcribe(
                        audioURL: URL(fileURLWithPath: "/tmp/take-\(index).wav"), spec: spec, language: nil,
                        prompt: nil)
                }
                // Queue them in a known order.
                try await Task.sleep(for: .milliseconds(5))
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(box.made.count, 1)
        XCTAssertEqual(box.made[0].maxTakesRunning, 1)
        XCTAssertEqual(box.made[0].requests.count, 4)
    }

    func testUnloadWaitsForTheRunningTakeThenReleasesTheModel() async throws {
        let spec = try installed(WhisperKitCatalog.small)
        let box = RunnerBox()
        box.mode = .blocksUntilCancelled
        let engine = makeEngine(box)

        let take = Task { try await engine.transcribe(audioURL: audio, spec: spec, language: nil, prompt: nil) }
        try await waitUntil("take started") { box.made.first?.startedTakes == 1 }

        await engine.unload()

        do {
            _ = try await take.value
            XCTFail("the take should have been cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let runner = box.made[0]
        XCTAssertEqual(runner.unloadCount, 1)
        XCTAssertEqual(runner.takesRunningAtUnload, [0], "released while a take was still running")
        XCTAssertEqual(runner.cancelledTakes, 1)
    }

    func testTheEngineWorksAfterAnUnloadDuringATake() async throws {
        let spec = try installed(WhisperKitCatalog.small)
        let box = RunnerBox()
        box.mode = .blocksUntilCancelled
        let engine = makeEngine(box)

        let take = Task { try await engine.transcribe(audioURL: audio, spec: spec, language: nil, prompt: nil) }
        try await waitUntil("take started") { box.made.first?.startedTakes == 1 }
        await engine.unload()
        _ = await take.result

        box.mode = .instant
        let text = try await engine.transcribe(audioURL: audio, spec: spec, language: nil, prompt: nil)
        XCTAssertEqual(text, "hello world")
        XCTAssertEqual(box.made.count, 2)
    }

    // MARK: Cancel

    func testCancellingARunningTakeStopsItAndFreesTheEngine() async throws {
        let spec = try installed(WhisperKitCatalog.small)
        let box = RunnerBox()
        box.mode = .blocksUntilCancelled
        let engine = makeEngine(box)

        let take = Task { try await engine.transcribe(audioURL: audio, spec: spec, language: nil, prompt: nil) }
        try await waitUntil("take started") { box.made.first?.startedTakes == 1 }
        take.cancel()

        do {
            _ = try await take.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(box.made[0].cancelledTakes, 1)

        // The engine is free again: the next take runs.
        box.made[0].mode = .instant
        let text = try await engine.transcribe(audioURL: audio, spec: spec, language: nil, prompt: nil)
        XCTAssertEqual(text, "hello world")
    }

    func testCancellingAQueuedTakeLeavesTheRunningOneAlone() async throws {
        let spec = try installed(WhisperKitCatalog.small)
        let box = RunnerBox()
        box.mode = .blocksUntilCancelled
        let engine = makeEngine(box)

        let first = Task { try await engine.transcribe(audioURL: audio, spec: spec, language: nil, prompt: nil) }
        try await waitUntil("first started") { box.made.first?.startedTakes == 1 }
        let queued = Task { try await engine.transcribe(audioURL: audio, spec: spec, language: nil, prompt: nil) }
        try await Task.sleep(for: .milliseconds(30))
        queued.cancel()

        do {
            _ = try await queued.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(box.made[0].startedTakes, 1, "the queued take must never reach WhisperKit")
        XCTAssertEqual(box.made[0].cancelledTakes, 0, "the running take must not be cancelled")

        first.cancel()
        _ = await first.result
    }

    func testATaskCancelledBeforeItStartsNeverReachesWhisperKit() async throws {
        let spec = try installed(WhisperKitCatalog.small)
        let box = RunnerBox()
        let engine = makeEngine(box)

        let cancelledUpFront = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await engine.transcribe(audioURL: audio, spec: spec, language: nil, prompt: nil)
                return false
            } catch {
                return error is CancellationError
            }
        }
        let threwCancellation = await cancelledUpFront.value
        XCTAssertTrue(threwCancellation)
        XCTAssertTrue(box.made.isEmpty)
    }

    // MARK: Live windows

    func testALiveWindowRunsOnTheLoadedModelWithTheBareLanguageAndPrompt() async throws {
        let spec = try installed(WhisperKitCatalog.small)
        let box = RunnerBox()
        let engine = makeEngine(box)
        try await engine.load(spec)

        let result = try await engine.transcribeLive(
            samples: [Float](repeating: 0.1, count: 16_000), spec: spec, language: "en-US", prompt: "  Pnoe  ")

        XCTAssertEqual(result?.segments.map(\.text), [" live words"])
        let live = try XCTUnwrap(box.made[0].liveRequests.first)
        XCTAssertEqual(live.samples, 16_000)
        XCTAssertEqual(live.language, "en")
        XCTAssertEqual(live.prompt, "Pnoe")
        XCTAssertEqual(box.made.count, 1)
    }

    func testALiveWindowIsDroppedWhenNoModelIsLoaded() async throws {
        let spec = try installed(WhisperKitCatalog.small)
        let box = RunnerBox()
        let engine = makeEngine(box)

        let result = try await engine.transcribeLive(samples: [0.1], spec: spec, language: nil, prompt: nil)

        XCTAssertNil(result)
        XCTAssertTrue(box.made.isEmpty, "a live window must not load the model")
    }

    func testALiveWindowIsDroppedWhileATakeRuns() async throws {
        let spec = try installed(WhisperKitCatalog.small)
        let box = RunnerBox()
        box.mode = .blocksUntilCancelled
        let engine = makeEngine(box)
        try await engine.load(spec)

        let take = Task { try await engine.transcribe(audioURL: audio, spec: spec, language: nil, prompt: nil) }
        try await waitUntil("take started") { box.made.first?.startedTakes == 1 }

        let result = try await engine.transcribeLive(samples: [0.1], spec: spec, language: nil, prompt: nil)

        XCTAssertNil(result)
        XCTAssertTrue(box.made[0].liveRequests.isEmpty)
        take.cancel()
        _ = await take.result
    }

    func testALiveWindowIsDroppedWhileAnotherLiveWindowRuns() async throws {
        let spec = try installed(WhisperKitCatalog.small)
        let box = RunnerBox()
        box.mode = .blocksUntilCancelled
        let engine = makeEngine(box)
        try await engine.load(spec)

        let first = Task { try await engine.transcribeLive(samples: [0.1], spec: spec, language: nil, prompt: nil) }
        try await waitUntil("live started") { box.made.first?.liveRequests.count == 1 }

        let second = try await engine.transcribeLive(samples: [0.1], spec: spec, language: nil, prompt: nil)

        XCTAssertNil(second)
        XCTAssertEqual(box.made[0].liveRequests.count, 1)
        first.cancel()
        _ = await first.result
    }

    func testATakeWaitsForARunningLiveWindowAndNeverOverlapsIt() async throws {
        let spec = try installed(WhisperKitCatalog.small)
        let box = RunnerBox()
        box.mode = .blocksUntilCancelled
        let engine = makeEngine(box)
        try await engine.load(spec)

        let live = Task { try await engine.transcribeLive(samples: [0.1], spec: spec, language: nil, prompt: nil) }
        try await waitUntil("live started") { box.made.first?.liveRequests.count == 1 }
        let take = Task { try await engine.transcribe(audioURL: audio, spec: spec, language: nil, prompt: nil) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(box.made[0].startedTakes, 0, "the take must wait for the live window")

        // Cancelling the live window (what the live session does at stop) lets the take through.
        box.made[0].mode = .instant
        live.cancel()
        _ = await live.result
        let text = try await take.value

        XCTAssertEqual(text, "hello world")
        XCTAssertEqual(box.made[0].maxTakesRunning, 1)
    }

    func testCancellingALiveWindowStopsItAndFreesTheEngine() async throws {
        let spec = try installed(WhisperKitCatalog.small)
        let box = RunnerBox()
        box.mode = .blocksUntilCancelled
        let engine = makeEngine(box)
        try await engine.load(spec)

        let live = Task { try await engine.transcribeLive(samples: [0.1], spec: spec, language: nil, prompt: nil) }
        try await waitUntil("live started") { box.made.first?.liveRequests.count == 1 }
        live.cancel()

        do {
            _ = try await live.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(box.made[0].cancelledLives, 1)
        box.made[0].mode = .instant
        let text = try await engine.transcribe(audioURL: audio, spec: spec, language: nil, prompt: nil)
        XCTAssertEqual(text, "hello world")
    }

    func testUnloadCancelsARunningLiveWindowBeforeReleasingTheModel() async throws {
        let spec = try installed(WhisperKitCatalog.small)
        let box = RunnerBox()
        box.mode = .blocksUntilCancelled
        let engine = makeEngine(box)
        try await engine.load(spec)

        let live = Task { try await engine.transcribeLive(samples: [0.1], spec: spec, language: nil, prompt: nil) }
        try await waitUntil("live started") { box.made.first?.liveRequests.count == 1 }
        await engine.unload()
        _ = await live.result

        XCTAssertEqual(box.made[0].cancelledLives, 1)
        XCTAssertEqual(box.made[0].unloadCount, 1)
        XCTAssertEqual(box.made[0].takesRunningAtUnload, [0])
    }

    func testAfterTheLiveSessionStopsTheFinalDecodeRunsOnceAndAlone() async throws {
        let spec = try installed(WhisperKitCatalog.small)
        let box = RunnerBox()
        let engine = makeEngine(box)
        try await engine.load(spec)

        let partials = LivePartials()
        let session = WhisperKitLiveSession(
            decoder: WhisperKitEngineLiveDecoder(engine: engine, spec: spec), language: "en", prompt: nil,
            onPartial: { partials.add($0) })
        await session.append([Float](repeating: 0.1, count: 32_000))
        await session.start(interval: .milliseconds(10))
        try await waitUntil("a live window ran") { box.made.first?.liveRequests.count == 1 }
        await session.stop()
        let liveWindows = box.made[0].liveRequests.count

        let text = try await engine.transcribe(audioURL: audio, spec: spec, language: "en", prompt: nil)

        XCTAssertEqual(text, "hello world")
        XCTAssertEqual(box.made[0].requests.count, 1, "the final decode runs once")
        XCTAssertEqual(box.made[0].liveRequests.count, liveWindows, "no live window after stop")
        XCTAssertEqual(box.made[0].maxTakesRunning, 1, "a live window and the final decode never overlap")
        XCTAssertEqual(partials.all.first, "live words")
        XCTAssertEqual(box.made.count, 1)
    }
}

private final class LivePartials: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ text: String) { lock.withLock { values.append(text) } }
    var all: [String] { lock.withLock { values } }
}
