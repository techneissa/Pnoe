import XCTest

/// Stands in for the WhisperKit package: records what the engine asks of it.
private final class FakeRunner: WhisperKitRunner, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var loadedFolders: [URL] = []
    private(set) var tokenizerBases: [URL] = []
    private(set) var requests: [(audio: URL, language: String?, prompt: String?)] = []
    private(set) var unloadCount = 0
    var reply = "  hello world \n"
    var failLoad = false

    func load(modelFolder: URL, tokenizerBase: URL) async throws {
        lock.withLock {
            loadedFolders.append(modelFolder)
            tokenizerBases.append(tokenizerBase)
        }
        if failLoad { throw CocoaError(.fileReadCorruptFile) }
    }

    func transcribe(audioURL: URL, language: String?, prompt: String?) async throws -> String {
        lock.withLock { requests.append((audioURL, language, prompt)) }
        return reply
    }

    func unload() async {
        lock.withLock { unloadCount += 1 }
    }
}

private final class RunnerBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var made: [FakeRunner] = []
    var failLoad = false

    func make() -> FakeRunner {
        let runner = FakeRunner()
        runner.failLoad = failLoad
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
            tokenizerRevision: spec.tokenizerRevision, tokenizerBytes: spec.tokenizerBytes,
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
        try Data("{}".utf8).write(to: tokenizer.appendingPathComponent("tokenizer.json"))
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
}
