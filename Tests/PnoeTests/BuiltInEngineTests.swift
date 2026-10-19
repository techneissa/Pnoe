import FormatterCore
import FormatterModels
import FormatterXPC
import Foundation
import XCTest

/// Fake stores on disk: a Hugging Face cache, LM Studio's folder, Ollama's model store and a chosen file, all
/// in a temporary folder. Nothing reads the real home folder and no model is loaded.
private final class FakeMac {
    let root: URL
    let hub: URL
    let lmStudio: URL
    let ollama: URL
    let artifactRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BuiltInTests-\(UUID().uuidString)")
        hub = root.appendingPathComponent("hub")
        lmStudio = root.appendingPathComponent("lm")
        ollama = root.appendingPathComponent("ollama")
        artifactRoot = root.appendingPathComponent("pnoe")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(_ path: String, _ contents: String = "GGUF-fake-model-bytes", under base: URL? = nil) throws -> URL {
        let url = (base ?? root).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func addHuggingFaceModel(_ repo: String = "unsloth--gemma-4-E2B-it-GGUF", file: String = "gemma-4-E2B-it-Q4_K_M.gguf") throws {
        try write("models--\(repo)/snapshots/r1/\(file)", under: hub)
        try write("models--\(repo)/refs/main", "r1", under: hub)
    }

    func addOllamaModel(_ model: String = "gemma3", tag: String = "4b") throws {
        let digest = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try write("blobs/sha256-\(digest)", "GGUF-fake-model-bytes", under: ollama)
        try write(
            "manifests/registry.ollama.ai/library/\(model)/\(tag)",
            #"{"layers":[{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:\#(digest)","size":21}]}"#,
            under: ollama)
    }

    var configuration: FormatterModelCatalog.Configuration {
        FormatterModelCatalog.Configuration(
            environment: [:],
            homeDirectory: root,
            huggingFaceHubDirectory: hub,
            lmStudioModelsDirectory: lmStudio,
            ollamaStoreDirectory: ollama
        )
    }

    var artifact: FormatterModelArtifact { .gemma4E2B(rootDirectory: artifactRoot) }
}

final class BuiltInModelListingTests: XCTestCase {
    func testListsGGUFFilesFromEveryStoreAndNothingFromTheRealHome() async throws {
        let mac = try FakeMac()
        try mac.addHuggingFaceModel()
        try mac.write("pub/Qwen3-4B-GGUF/Qwen3-4B-Q8_0.gguf", under: mac.lmStudio)
        try mac.addOllamaModel("gemma3", tag: "4b")
        let chosen = try mac.write("mine/custom-Q5_K_M.gguf")
        // A plain text file is not a model for this engine.
        try mac.write("pub/notes/README.md", "x", under: mac.lmStudio)

        let entries = await BuiltInModels.installed(chosenFiles: [chosen], artifact: mac.artifact, catalog: mac.configuration)
        XCTAssertEqual(
            Set(entries.map(\.source)), [.huggingFaceCache, .lmStudio, .ollamaStore, .userChosen])
        XCTAssertEqual(entries.count, 4)
        XCTAssertTrue(entries.allSatisfy { $0.kind == .gguf && $0.spec.modelURL != nil })
        XCTAssertTrue(entries.contains { $0.displayName == "gemma3:4b" && $0.source == .ollamaStore })
    }

    func testMLXFoldersAreListedNextToTheGGUFFilesWithTheirOwnEngine() async throws {
        let mac = try FakeMac()
        try mac.addHuggingFaceModel()
        // An MLX build in the Hugging Face cache, one in LM Studio's folder and a folder the user chose.
        let config = #"{"model_type":"gemma4","quantization":{"group_size":64,"bits":4}}"#
        try mac.write("models--mlx-community--gemma-4-e2b-it-4bit/snapshots/r1/config.json", config, under: mac.hub)
        try mac.write("models--mlx-community--gemma-4-e2b-it-4bit/snapshots/r1/model.safetensors", "weights", under: mac.hub)
        try mac.write("models--mlx-community--gemma-4-e2b-it-4bit/refs/main", "r1", under: mac.hub)
        try mac.write("mlx-community/Qwen3-4B-4bit/config.json", config, under: mac.lmStudio)
        try mac.write("mlx-community/Qwen3-4B-4bit/model.safetensors", "weights", under: mac.lmStudio)
        let chosenFolder = try mac.write("mine/my-mlx/config.json", "{}").deletingLastPathComponent()
        try mac.write("mine/my-mlx/model.safetensors", "weights")

        let entries = await BuiltInModels.installed(chosenFiles: [chosenFolder], artifact: mac.artifact, catalog: mac.configuration)
        let mlx = entries.filter { $0.kind == .mlx }
        XCTAssertEqual(Set(mlx.map(\.source)), [.huggingFaceCache, .lmStudio, .userChosen])
        XCTAssertEqual(mlx.count, 3)
        XCTAssertEqual(entries.filter { $0.kind == .gguf }.count, 1)
        // The spec carries the engine: a folder is routed to the MLX service, a file to llama.cpp.
        XCTAssertTrue(mlx.allSatisfy { $0.spec.backend == .mlx })
        XCTAssertTrue(entries.filter { $0.kind == .gguf }.allSatisfy { $0.spec.backend == nil })

        let id = try XCTUnwrap(mlx.first { $0.source == .lmStudio }?.id)
        let spec = await BuiltInModels.spec(forID: id, chosenFiles: [chosenFolder], artifact: mac.artifact, catalog: mac.configuration)
        XCTAssertEqual(spec?.backend, .mlx)
        XCTAssertEqual(spec?.contextLength, BuiltInModels.contextLength)
        XCTAssertTrue(BuiltInModels.isInstalled(modelID: id, chosenFiles: [chosenFolder], artifact: mac.artifact, catalog: mac.configuration))
    }

    func testAnMLXModelIsNeverPreselected() async throws {
        let mac = try FakeMac()
        let config = #"{"quantization":{"bits":4}}"#
        try mac.write("mlx-community/gemma-4-e2b-it-4bit/config.json", config, under: mac.lmStudio)
        try mac.write("mlx-community/gemma-4-e2b-it-4bit/model.safetensors", "weights", under: mac.lmStudio)
        let entries = await BuiltInModels.installed(chosenFiles: [], artifact: mac.artifact, catalog: mac.configuration)
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(BuiltInModels.suggested(from: entries))
        XCTAssertNil(BuiltInModels.selection(stored: nil, installed: entries))
    }

    func testTheEngineRoutesAGGUFAndAnMLXModelToTheirOwnService() async throws {
        let mac = try FakeMac()
        try mac.addHuggingFaceModel()
        let config = #"{"quantization":{"bits":4}}"#
        try mac.write("mlx-community/gemma-4-e2b-it-4bit/config.json", config, under: mac.lmStudio)
        try mac.write("mlx-community/gemma-4-e2b-it-4bit/model.safetensors", "weights", under: mac.lmStudio)
        let entries = await BuiltInModels.installed(chosenFiles: [], artifact: mac.artifact, catalog: mac.configuration)
        let gguf = try XCTUnwrap(entries.first { $0.kind == .gguf })
        let mlxEntry = try XCTUnwrap(entries.first { $0.kind == .mlx })

        let llama = FakeRuntime(id: .llama, handler: { _ in GenerationResult(text: "llama") })
        let mlx = FakeRuntime(id: .mlx, handler: { _ in GenerationResult(text: "mlx") })
        let engine = BuiltInEngine(
            runtime: RoutingFormatterRuntime(backends: [.llama: llama, .mlx: mlx], fallback: .llama),
            chosenFiles: { [] }, artifact: { mac.artifact }, catalog: { mac.configuration })

        let viaMLX = try await engine.complete(system: "rules", user: "hello", modelID: mlxEntry.id, timeout: 5)
        XCTAssertEqual(viaMLX, "mlx")
        let viaLlama = try await engine.complete(system: "rules", user: "hello", modelID: gguf.id, timeout: 5)
        XCTAssertEqual(viaLlama, "llama")
        let mlxPrepares = await mlx.prepareCalls
        let llamaPrepares = await llama.prepareCalls
        XCTAssertEqual(mlxPrepares.count, 1)
        XCTAssertEqual(mlxPrepares.first?.0.modelURL, mlxEntry.spec.modelURL)
        XCTAssertEqual(llamaPrepares.count, 1)
        XCTAssertEqual(llamaPrepares.first?.0.modelURL, gguf.spec.modelURL)

        // A memory-pressure or quit unload frees both services.
        await engine.unload()
        let mlxUnloads = await mlx.unloadCount
        let llamaUnloads = await llama.unloadCount
        XCTAssertEqual(mlxUnloads, 1)
        XCTAssertEqual(llamaUnloads, 1)
    }

    func testTheDownloadedModelIsListedFirstOnceItIsInstalled() async throws {
        let mac = try FakeMac()
        try mac.addHuggingFaceModel()
        var entries = await BuiltInModels.installed(chosenFiles: [], artifact: mac.artifact, catalog: mac.configuration)
        XCTAssertEqual(entries.map(\.source), [.huggingFaceCache])

        // An install is the file at the right size with the checksum marker; here a stand-in with both.
        let artifact = mac.artifact
        try FileManager.default.createDirectory(at: artifact.modelDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: artifact.modelFileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: artifact.modelFileURL)
        try handle.truncate(atOffset: UInt64(artifact.expectedFileSize))
        try handle.close()
        try artifact.expectedSHA256.write(to: artifact.checksumFileURL, atomically: true, encoding: .utf8)

        entries = await BuiltInModels.installed(chosenFiles: [], artifact: artifact, catalog: mac.configuration)
        XCTAssertEqual(entries.map(\.source), [.downloaded, .huggingFaceCache])
        XCTAssertEqual(entries.first?.id, BuiltInModels.downloadedID(for: artifact))
        XCTAssertEqual(entries.first?.displayName, "Gemma 4 E2B")
    }

    func testAStoredIdResolvesToItsFileAndAMissingModelToNothing() async throws {
        let mac = try FakeMac()
        try mac.addHuggingFaceModel()
        let entries = await BuiltInModels.installed(chosenFiles: [], artifact: mac.artifact, catalog: mac.configuration)
        let id = try XCTUnwrap(entries.first?.id)
        let spec = await BuiltInModels.spec(forID: id, chosenFiles: [], artifact: mac.artifact, catalog: mac.configuration)
        XCTAssertEqual(spec?.modelURL?.lastPathComponent, "gemma-4-E2B-it-Q4_K_M.gguf")
        XCTAssertEqual(spec?.contextLength, BuiltInModels.contextLength)

        let gone = await BuiltInModels.spec(forID: "hf:nobody/nothing/x.gguf", chosenFiles: [], artifact: mac.artifact, catalog: mac.configuration)
        XCTAssertNil(gone)
    }

    func testListingChangesNoFile() async throws {
        let mac = try FakeMac()
        try mac.addHuggingFaceModel()
        try mac.addOllamaModel()
        func snapshot() -> [String] {
            let walker = FileManager.default.enumerator(at: mac.root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])!
            return walker.compactMap { item -> String? in
                guard let url = item as? URL, let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                else { return nil }
                return "\(url.path) \(values.fileSize ?? -1) \(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            }.sorted()
        }
        let before = snapshot()
        _ = await BuiltInModels.installed(chosenFiles: [], artifact: mac.artifact, catalog: mac.configuration)
        XCTAssertEqual(before, snapshot())
    }

    func testPickerTextShowsSizeQuantizationAndWhereItCameFrom() {
        let entry = FormatterModelEntry(
            id: "hf:x/y/z.gguf", displayName: "z", kind: .gguf, sizeBytes: 3_100_000_000, source: .huggingFaceCache,
            quantization: "Q4_K_M", spec: RuntimeModelSpec(modelURL: URL(fileURLWithPath: "/m/z.gguf")))
        XCTAssertEqual(BuiltInModels.detail(of: entry), "3.1 GB · Q4_K_M · Hugging Face")
    }
}

final class BuiltInSelectionTests: XCTestCase {
    private func entry(_ name: String, gigabytes: Double, source: FormatterModelSource = .huggingFaceCache) -> FormatterModelEntry {
        FormatterModelEntry(
            id: "\(source.rawValue):\(name)", displayName: name, kind: .gguf, sizeBytes: Int64(gigabytes * 1_000_000_000),
            source: source, spec: RuntimeModelSpec(modelURL: URL(fileURLWithPath: "/m/\(name).gguf")))
    }

    func testTheDownloadedModelIsTheStartingChoice() {
        let entries = [entry("gemma-3-4b-it-Q4_K_M", gigabytes: 2.5), entry("Gemma 4 E2B", gigabytes: 3.1, source: .downloaded)]
        XCTAssertEqual(BuiltInModels.suggested(from: entries)?.source, .downloaded)
    }

    func testOtherwiseTheSmallestInstructGemmaOrQwen() {
        let entries = [
            entry("gemma-3-12b-it-Q4_K_M", gigabytes: 7),
            entry("Qwen3-4B-Q8_0", gigabytes: 4.2),
            entry("gemma-3-4b-it-Q4_K_M", gigabytes: 2.5),
            entry("gemma-3-4b-pt-Q4_K_M", gigabytes: 2.0),
            entry("llama-3.2-3b-instruct", gigabytes: 1.9),
            entry("qwen2.5-coder-7b", gigabytes: 4),
        ]
        XCTAssertEqual(BuiltInModels.suggested(from: entries)?.displayName, "gemma-3-4b-it-Q4_K_M")
        XCTAssertNil(BuiltInModels.suggested(from: [entry("llama-3.2-3b-instruct", gigabytes: 1.9)]))
        XCTAssertNil(BuiltInModels.suggested(from: []))
    }

    func testAStoredChoiceStaysEvenWhenThatModelIsGoneAndOnlyAnEmptyOneGetsTheSuggestion() {
        let a = entry("gemma-3-4b-it", gigabytes: 2.5)
        let b = entry("Qwen3-4B", gigabytes: 4.2)
        XCTAssertEqual(BuiltInModels.selection(stored: b.id, installed: [a, b]), b.id)
        // An unplugged drive: the stored model is kept, the picker says "Model not found".
        XCTAssertEqual(BuiltInModels.selection(stored: "gone", installed: [a, b]), "gone")
        XCTAssertEqual(BuiltInModels.selection(stored: "gone", installed: []), "gone")
        // Nothing stored yet: the suggestion.
        XCTAssertEqual(BuiltInModels.selection(stored: nil, installed: [a, b]), a.id)
        XCTAssertEqual(BuiltInModels.selection(stored: "", installed: [a, b]), a.id)
        XCTAssertNil(BuiltInModels.selection(stored: nil, installed: []))
    }

    func testGemma4E2BComesFirstWhereverItIsInstalledEvenWhenASmallerModelExists() {
        let small = entry("Qwen3-1.7B-Q8_0", gigabytes: 1.8)
        let gemma = entry("gemma-4-E2B-it-Q4_K_M", gigabytes: 3.1)
        let other = entry("gemma-3-4b-it-Q4_K_M", gigabytes: 2.5)
        XCTAssertEqual(BuiltInModels.suggested(from: [small, other, gemma])?.id, gemma.id)
        let ollama = entry("gemma4:e2b", gigabytes: 7.2, source: .ollamaStore)
        XCTAssertEqual(BuiltInModels.suggested(from: [small, ollama])?.id, ollama.id)
        XCTAssertEqual(BuiltInModels.suggested(from: [small, other])?.id, small.id, "no Gemma 4 E2B: the smallest suitable")
    }

    func testOllamaStaysTheTemplateDefaultAndAGGUFFileNeverBecomesIt() async {
        let ollama = FormatterModelEntry(
            id: "ollama:gemma3:4b", displayName: "gemma3:4b", kind: .ollama, sizeBytes: 3_300_000_000, source: .ollama,
            spec: RuntimeModelSpec(identifier: "gemma3:4b"))
        let storeCopy = entry("gemma3:4b", gigabytes: 3.3, source: .ollamaStore)
        let choice = await TemplateProviderPreselection.choose { [storeCopy, ollama] }
        XCTAssertEqual(choice, PreselectedProvider(providerName: "Ollama", modelName: "gemma3:4b"))
        // With Ollama not running, only files are found, and no provider is preselected.
        let none = await TemplateProviderPreselection.choose { [storeCopy] }
        XCTAssertNil(none)
    }

    func testBuiltInIsAlwaysOfferedAfterOllamaAndNothingElseMoves() {
        let order = ["Cerebras", "Groq", "Gemini", "Ollama", "Built-in", "Local CLI", "Custom"]
        XCTAssertEqual(
            WorkflowProviderList.names(order: order, connected: [], builtIn: "Built-in"), ["Built-in"])
        XCTAssertEqual(
            WorkflowProviderList.names(order: order, connected: ["Gemini", "Ollama"], builtIn: "Built-in"),
            ["Gemini", "Ollama", "Built-in"])
        XCTAssertEqual(
            WorkflowProviderList.names(order: order, connected: ["Groq", "Custom"], builtIn: "Built-in"),
            ["Groq", "Built-in", "Custom"])
    }

    func testTheDownloadRowAppearsOnlyForAMacWithNothingInstalledOrWhileADownloadRuns() {
        typealias Visibility = BuiltInDownloadVisibility
        XCTAssertTrue(Visibility.isVisible(installedCount: 0, state: .notInstalled))
        XCTAssertFalse(Visibility.isVisible(installedCount: 2, state: .notInstalled))
        XCTAssertTrue(Visibility.isVisible(installedCount: 2, state: .downloading(fraction: 0.4)))
        XCTAssertTrue(Visibility.isVisible(installedCount: 2, state: .failed("no space")))
        // A finished download shows Downloaded and Remove.
        XCTAssertTrue(Visibility.isVisible(installedCount: 0, state: .ready))
    }
}

final class BuiltInDownloadMotionTests: XCTestCase {
    func testTheDownloadFollowsItsPhasesForTheSymbolEffects() {
        XCTAssertEqual(FormatterModelDownloadState.notInstalled.motionPhase, .idle)
        for state in [FormatterModelDownloadState.downloading(fraction: 0.3), .paused, .verifying] {
            XCTAssertEqual(state.motionPhase, .running, "\(state)")
        }
        XCTAssertEqual(FormatterModelDownloadState.ready.motionPhase, .finished)
        XCTAssertEqual(FormatterModelDownloadState.failed("no space").motionPhase, .failed)
        // Nothing plays at idle, a loop only while it runs, one pass for a finish or a failure.
        XCTAssertEqual(Motion.symbolEffect(for: FormatterModelDownloadState.notInstalled.motionPhase, reduceMotion: false), .none)
        XCTAssertEqual(Motion.symbolEffect(for: FormatterModelDownloadState.paused.motionPhase, reduceMotion: false), .pulse)
        XCTAssertEqual(Motion.symbolEffect(for: FormatterModelDownloadState.ready.motionPhase, reduceMotion: false), .bounce)
        XCTAssertEqual(Motion.symbolEffect(for: FormatterModelDownloadState.failed("x").motionPhase, reduceMotion: false), .wiggle)
        XCTAssertEqual(Motion.symbol(for: .failed, idle: "arrow.down.circle", running: "xmark.circle"), "exclamationmark.triangle")
    }
}

final class BuiltInEngineRequestTests: XCTestCase {
    private func engine(_ runtime: any FormatterRuntime, mac: FakeMac) -> BuiltInEngine {
        BuiltInEngine(
            runtime: runtime, chosenFiles: { [] }, artifact: { mac.artifact }, catalog: { mac.configuration })
    }

    private func installedID(_ mac: FakeMac) async throws -> String {
        let entries = await BuiltInModels.installed(chosenFiles: [], artifact: mac.artifact, catalog: mac.configuration)
        return try XCTUnwrap(entries.first?.id)
    }

    func testAFreeFormRequestPreparesTheSystemPromptAsThePrefixAndReturnsTheAnswer() async throws {
        let mac = try FakeMac()
        try mac.addHuggingFaceModel()
        let fake = FakeRuntime(returning: "- buy milk")
        let id = try await installedID(mac)
        let text = try await engine(fake, mac: mac).complete(system: "Make a checklist.", user: "buy milk", modelID: id, timeout: 5)
        XCTAssertEqual(text, "- buy milk")
        let prepared = await fake.prepareCalls
        XCTAssertEqual(prepared.first?.1.messages, [ChatMessage(role: .system, content: "Make a checklist.")])
        XCTAssertEqual(prepared.first?.0.modelURL?.lastPathComponent, "gemma-4-E2B-it-Q4_K_M.gguf")
        let requests = await fake.requests
        XCTAssertEqual(requests.first?.suffix, [ChatMessage(role: .user, content: "buy milk")])
        XCTAssertEqual(requests.first?.temperature, 0)
    }

    func testAnAnswerThatHitTheCapOrTheDeadlineIsAnErrorNotPartialText() async throws {
        let mac = try FakeMac()
        try mac.addHuggingFaceModel()
        let id = try await installedID(mac)
        do {
            _ = try await engine(FakeRuntime(returning: "cut", stopReason: .cap), mac: mac)
                .complete(system: "s", user: "u", modelID: id, timeout: 5)
            XCTFail("expected outputTooLong")
        } catch { XCTAssertEqual(error as? BuiltInEngineError, .outputTooLong) }
        do {
            _ = try await engine(FakeRuntime(returning: "", stopReason: .interrupted), mac: mac)
                .complete(system: "s", user: "u", modelID: id, timeout: 5)
            XCTFail("expected timedOut")
        } catch { XCTAssertEqual(error as? BuiltInEngineError, .timedOut) }
    }

    func testAModelThatIsGoneIsReportedBeforeAnythingIsLoaded() async throws {
        let mac = try FakeMac()
        let fake = FakeRuntime(returning: "x")
        do {
            _ = try await engine(fake, mac: mac).complete(system: "s", user: "u", modelID: "hf:gone/x.gguf", timeout: 5)
            XCTFail("expected modelMissing")
        } catch { XCTAssertEqual(error as? BuiltInEngineError, .modelMissing) }
        let prepared = await fake.prepareCalls
        XCTAssertTrue(prepared.isEmpty)
    }

    func testCleanedTextRunsThroughTheSameGuardsAndFallsBackWhenTheModelIsGone() async throws {
        let mac = try FakeMac()
        try mac.addHuggingFaceModel()
        let id = try await installedID(mac)
        let take = "um so i think we should meet on tuesday at three"

        // A good answer is used.
        let good = FakeRuntime(returning: "I think we should meet on Tuesday at three.")
        let cleaned = await GuardedCleanup.makeBuiltIn(modelID: id, engine: engine(good, mac: mac)).clean(take)
        XCTAssertNil(cleaned.fallbackReason)
        XCTAssertEqual(cleaned.text, "I think we should meet on Tuesday at three.")

        // A rewrite is rejected by the word guard, as on the Ollama path.
        let rewrite = FakeRuntime(returning: "Let us schedule a gathering on Tuesday afternoon.")
        let guarded = await GuardedCleanup.makeBuiltIn(modelID: id, engine: engine(rewrite, mac: mac)).clean(take)
        XCTAssertNotNil(guarded.fallbackReason)
        XCTAssertFalse(guarded.text.contains("gathering"))

        // A model that was deleted gives the plain transcript, not an error.
        let gone = FakeRuntime(returning: "x")
        let missing = await GuardedCleanup.makeBuiltIn(modelID: "hf:gone/x.gguf", engine: engine(gone, mac: mac)).clean(take)
        XCTAssertNotNil(missing.fallbackReason)
        XCTAssertTrue(missing.text.lowercased().contains("tuesday"))
    }
}

/// The service dies in the middle of a take: the app stays up and the take pastes the plain transcript.
final class BuiltInServiceCrashTests: XCTestCase {
    private final class Connections: @unchecked Sendable {
        private let lock = NSLock()
        private var open: [NSXPCConnection] = []
        func add(_ connection: NSXPCConnection) { lock.lock(); open.append(connection); lock.unlock() }
        func killAll() { lock.lock(); let all = open; open = []; lock.unlock(); all.forEach { $0.invalidate() } }
    }

    private final class Tracking: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
        let inner: FormatterXPCListenerDelegate
        let connections: Connections
        init(_ inner: FormatterXPCListenerDelegate, _ connections: Connections) {
            self.inner = inner
            self.connections = connections
        }
        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            connections.add(connection)
            return inner.listener(listener, shouldAcceptNewConnection: connection)
        }
    }

    func testKillingTheServiceMidTakeFallsBackToThePlainTranscript() async throws {
        let mac = try FakeMac()
        try mac.addHuggingFaceModel()
        let entries = await BuiltInModels.installed(chosenFiles: [], artifact: mac.artifact, catalog: mac.configuration)
        let id = try XCTUnwrap(entries.first?.id)

        let connections = Connections()
        let entered = expectation(description: "the service is generating")
        let service = FakeRuntime { _ in
            entered.fulfill()
            try await Task.sleep(for: .seconds(30))
            return GenerationResult(text: "never")
        }
        let listener = NSXPCListener.anonymous()
        let delegate = Tracking(FormatterXPCListenerDelegate(runtime: service), connections)
        listener.delegate = delegate
        listener.resume()
        let client = XPCFormatterRuntime(endpoint: .listener(listener.endpoint))
        let engine = BuiltInEngine(
            runtime: client, chosenFiles: { [] }, artifact: { mac.artifact }, catalog: { mac.configuration })

        let take = "um so i think we should meet on tuesday at three"
        let running = Task { await GuardedCleanup.makeBuiltIn(modelID: id, engine: engine).clean(take) }
        await fulfillment(of: [entered], timeout: 10)
        connections.killAll()
        let result = await running.value
        withExtendedLifetime((listener, delegate)) {}

        XCTAssertEqual(result.fallbackReason, FallbackReason.runtimeCrashed.rawValue)
        XCTAssertTrue(result.text.lowercased().contains("tuesday"), "the take still pastes")
    }
}

// MARK: - Round 2 and review fixes

final class BuiltInPickerTextTests: XCTestCase {
    private func entry(_ name: String, quantization: String?, source: FormatterModelSource = .huggingFaceCache) -> FormatterModelEntry {
        FormatterModelEntry(
            id: "\(source.rawValue):\(name)", displayName: name, kind: .gguf, sizeBytes: 3_100_000_000, source: source,
            quantization: quantization, spec: RuntimeModelSpec(modelURL: URL(fileURLWithPath: "/m/\(name).gguf")))
    }

    func testTheTitleLosesItsQuantizationWhichHasABadgeOfItsOwn() {
        XCTAssertEqual(BuiltInModels.title(of: entry("gemma-4-E2B-it-Q4_K_M", quantization: "Q4_K_M")), "gemma-4-E2B-it")
        XCTAssertEqual(BuiltInModels.title(of: entry("gemma3:4b-it-q4_K_M", quantization: "Q4_K_M", source: .ollamaStore)), "gemma3:4b-it")
        XCTAssertEqual(BuiltInModels.title(of: entry("Qwen3-4B.Q8_0", quantization: "Q8_0")), "Qwen3-4B")
        XCTAssertEqual(BuiltInModels.title(of: entry("notes-cleanup", quantization: nil)), "notes-cleanup")
        // A name that only mentions it in the middle stays whole.
        XCTAssertEqual(BuiltInModels.title(of: entry("Q4_K_M-experiments", quantization: "Q4_K_M")), "Q4_K_M-experiments")
        XCTAssertEqual(BuiltInModels.title(of: entry("Q4_K_M", quantization: "Q4_K_M")), "Q4_K_M")
    }

    func testSourcesAreNamedAsTheMaintainerAsked() {
        XCTAssertEqual(
            [FormatterModelSource.huggingFaceCache, .lmStudio, .ollamaStore, .userChosen, .downloaded].map(BuiltInModels.sourceLabel),
            ["Hugging Face", "LM Studio", "Ollama", "File", "Downloaded"])
    }

    func testSearchMatchesNameQuantizationAndSourceAndEveryWordOfTheQuery() {
        let rows = [
            BuiltInModelRow(entry: entry("gemma-4-E2B-it-Q4_K_M", quantization: "Q4_K_M")),
            BuiltInModelRow(entry: entry("Qwen3-4B-Instruct-Q8_0", quantization: "Q8_0", source: .lmStudio)),
            BuiltInModelRow(entry: entry("gemma3:4b-it-q4_K_M", quantization: "Q4_K_M", source: .ollamaStore)),
        ]
        func names(_ query: String) -> [String] { BuiltInModelSearch.filter(rows, query: query).map(\.name) }
        XCTAssertEqual(names("").count, 3)
        XCTAssertEqual(names("QWEN"), ["Qwen3-4B-Instruct"])
        XCTAssertEqual(names("q4_k"), ["gemma-4-E2B-it", "gemma3:4b-it"])
        XCTAssertEqual(names("lm studio"), ["Qwen3-4B-Instruct"])
        XCTAssertEqual(names("ollama q4"), ["gemma3:4b-it"])
        XCTAssertEqual(names("gemma hugging"), ["gemma-4-E2B-it"])
        XCTAssertEqual(names("nothing like this"), [])
    }

    private func mlxEntry(
        _ name: String, bits: String = "4bit", source: FormatterModelSource = .huggingFaceCache
    ) -> FormatterModelEntry {
        FormatterModelEntry(
            id: "\(source.rawValue):\(name)", displayName: name, kind: .mlx, sizeBytes: 2_000_000_000, source: source,
            quantization: bits, spec: RuntimeModelSpec(modelURL: URL(fileURLWithPath: "/m/\(name)"), backend: .mlx))
    }

    func testAnMLXModelHasAnMLXBadgeAndIsFoundBySearchingForIt() {
        let rows = [
            BuiltInModelRow(entry: entry("gemma-4-E2B-it-Q4_K_M", quantization: "Q4_K_M")),
            BuiltInModelRow(entry: mlxEntry("gemma-4-e2b-it-4bit")),
            BuiltInModelRow(entry: mlxEntry("Qwen3-4B-8bit", bits: "8bit", source: .lmStudio)),
        ]
        XCTAssertEqual(rows.map(\.isMLX), [false, true, true])
        // The badge carries the engine and the quantization badge the bit width, so the name loses the suffix.
        XCTAssertEqual(rows[1].name, "gemma-4-e2b-it")
        XCTAssertEqual(rows[1].quantization, "4bit")
        func names(_ query: String) -> [String] { BuiltInModelSearch.filter(rows, query: query).map(\.name) }
        XCTAssertEqual(names("mlx"), ["gemma-4-e2b-it", "Qwen3-4B"])
        XCTAssertEqual(names("mlx lm studio"), ["Qwen3-4B"])
        XCTAssertEqual(names("8bit"), ["Qwen3-4B"])
        XCTAssertEqual(names("gemma"), ["gemma-4-E2B-it", "gemma-4-e2b-it"])
    }

    func testAnMLXModelsDetailLineNamesTheEngine() {
        XCTAssertEqual(
            BuiltInModels.detail(of: mlxEntry("gemma-4-e2b-it-4bit")), "2 GB · 4bit · MLX · Hugging Face")
    }

    func testSourcesWithALogoUseItAndTheOthersKeepTheirSymbol() {
        XCTAssertEqual(BuiltInModelStyle.logo(for: .ollama), "provider-ollama")
        XCTAssertEqual(BuiltInModelStyle.logo(for: .ollamaStore), "provider-ollama")
        XCTAssertEqual(BuiltInModelStyle.logo(for: .huggingFaceCache), "provider-huggingface")
        XCTAssertEqual(BuiltInModelStyle.logo(for: .lmStudio), "provider-lmstudio")
        XCTAssertNil(BuiltInModelStyle.logo(for: .userChosen))
        XCTAssertNil(BuiltInModelStyle.logo(for: .downloaded))
    }

    func testPlaygroundListsAnMLXModelNextToTheGGUFOnes() {
        let rows = [
            BuiltInModelRow(entry: entry("gemma-4-E2B-it-Q4_K_M", quantization: "Q4_K_M")),
            BuiltInModelRow(entry: mlxEntry("gemma-4-e2b-it-4bit")),
        ]
        XCTAssertEqual(
            PlaygroundModelOptions.builtIn(rows, providerName: "Built-in").map(\.label),
            ["Built-in · gemma-4-E2B-it", "Built-in · gemma-4-e2b-it"])
    }

    func testPlaygroundListsBuiltInModelsByNameAndTheWorkflowsOwnChoiceTakesTheName() {
        let rows = [BuiltInModelRow(entry: entry("gemma-4-E2B-it-Q4_K_M", quantization: "Q4_K_M"))]
        let listed = PlaygroundModelOptions.builtIn(rows, providerName: "Built-in")
        XCTAssertEqual(listed.map(\.label), ["Built-in · gemma-4-E2B-it"])
        XCTAssertEqual(listed.first?.model, rows[0].id, "the model is the id the workflow stores")

        // The workflow's own choice only has the id; the merged list shows the name, once.
        let own = PlaygroundModelChoice(provider: "Built-in", model: rows[0].id)
        let merged = PlaygroundModelOptions.merged(listed, own: own)
        XCTAssertEqual(merged.map(\.label), ["Built-in · gemma-4-E2B-it"])
        XCTAssertEqual(own, listed[0], "the same choice, so picking it is not an override")
    }
}

final class BuiltInDefaultsTests: XCTestCase {
    private func gguf(_ name: String, source: FormatterModelSource = .huggingFaceCache) -> FormatterModelEntry {
        FormatterModelEntry(
            id: "\(source.rawValue):\(name)", displayName: name, kind: .gguf, sizeBytes: 3_000_000_000, source: source,
            spec: RuntimeModelSpec(modelURL: URL(fileURLWithPath: "/m/\(name).gguf")))
    }

    private var ollama: FormatterModelEntry {
        FormatterModelEntry(
            id: "ollama:gemma3:4b", displayName: "gemma3:4b", kind: .ollama, sizeBytes: 3_300_000_000, source: .ollama,
            spec: RuntimeModelSpec(identifier: "gemma3:4b"))
    }

    func testANewLocalWorkflowStartsOnOllamaWhenItRuns() async {
        let choice = await TemplateProviderPreselection.chooseLocal(
            ollama: { [self.ollama] }, builtIn: { [self.gguf("gemma-4-E2B-it-Q4_K_M")] })
        XCTAssertEqual(choice, PreselectedProvider(providerName: "Ollama", modelName: "gemma3:4b"))
    }

    func testWithOllamaNotRunningItStartsOnAnInstalledBuiltInModel() async {
        let gemma = gguf("gemma-4-E2B-it-Q4_K_M")
        let choice = await TemplateProviderPreselection.chooseLocal(ollama: { [] }, builtIn: { [gemma] })
        XCTAssertEqual(choice, PreselectedProvider(providerName: "Built-in", modelName: gemma.id))
    }

    func testWithNeitherItIsNeverBuiltInAndTheEditorKeepsWhatItWouldPickAnyway() async {
        let choice = await TemplateProviderPreselection.chooseLocal(ollama: { [] }, builtIn: { [] })
        XCTAssertNil(choice)
        // A Built-in model nobody would run (a base or tiny file) is not a model to start on either.
        let base = await TemplateProviderPreselection.chooseLocal(ollama: { [] }, builtIn: { [self.gguf("llama-3.2-1b-instruct")] })
        XCTAssertNil(base)

        let on = ["Gemini", "Built-in"]
        XCTAssertEqual(TemplateProviderPreselection.defaultProvider(inherited: nil, available: on, builtIn: "Built-in"), "Gemini")
        XCTAssertNil(TemplateProviderPreselection.defaultProvider(inherited: nil, available: ["Built-in"], builtIn: "Built-in"))
        XCTAssertEqual(
            TemplateProviderPreselection.defaultProvider(inherited: "Groq", available: ["Groq", "Built-in"], builtIn: "Built-in"), "Groq")
        XCTAssertEqual(
            TemplateProviderPreselection.defaultProvider(inherited: "Groq", available: on, builtIn: "Built-in"), "Gemini",
            "an inherited provider that is not on offer falls back as before")
    }

    func testABuiltInWorkflowIsInheritedOnlyWithItsInstalledModelOtherwiseTheNormalPick() {
        let offered = ["Gemini", "Built-in"]
        // The active workflow is Built-in and its model is on the Mac: the new one inherits both.
        XCTAssertEqual(
            TemplateProviderPreselection.defaultProvider(
                inherited: "Built-in", available: offered, builtIn: "Built-in", builtInModelInstalled: true),
            "Built-in")
        // Its model is gone, or nothing is installed: no Built-in without a model, the normal pick instead.
        XCTAssertEqual(
            TemplateProviderPreselection.defaultProvider(
                inherited: "Built-in", available: offered, builtIn: "Built-in", builtInModelInstalled: false),
            "Gemini")
        XCTAssertNil(
            TemplateProviderPreselection.defaultProvider(
                inherited: "Built-in", available: ["Built-in"], builtIn: "Built-in"))
        // Another inherited provider is not affected by the flag.
        XCTAssertEqual(
            TemplateProviderPreselection.defaultProvider(inherited: "Gemini", available: offered, builtIn: "Built-in"), "Gemini")
    }

    func testTheInheritedModelCountsAsInstalledOnlyWhileItsFileIsThere() async throws {
        let mac = try FakeMac()
        try mac.addHuggingFaceModel()
        let entries = await BuiltInModels.installed(chosenFiles: [], artifact: mac.artifact, catalog: mac.configuration)
        let id = try XCTUnwrap(entries.first?.id)
        XCTAssertTrue(BuiltInModels.isInstalled(modelID: id, chosenFiles: [], artifact: mac.artifact, catalog: mac.configuration))
        XCTAssertFalse(BuiltInModels.isInstalled(modelID: "hf:gone/x.gguf", chosenFiles: [], artifact: mac.artifact, catalog: mac.configuration))
        XCTAssertFalse(BuiltInModels.isInstalled(modelID: nil, chosenFiles: [], artifact: mac.artifact, catalog: mac.configuration))
        XCTAssertFalse(BuiltInModels.isInstalled(modelID: "", chosenFiles: [], artifact: mac.artifact, catalog: mac.configuration))
        // A chosen file is installed while the file exists.
        let chosen = try mac.write("mine/custom-Q5_K_M.gguf")
        let chosenID = "file:" + chosen.standardizedFileURL.path
        XCTAssertTrue(BuiltInModels.isInstalled(modelID: chosenID, chosenFiles: [chosen], artifact: mac.artifact, catalog: mac.configuration))
        try FileManager.default.removeItem(at: chosen)
        XCTAssertFalse(BuiltInModels.isInstalled(modelID: chosenID, chosenFiles: [chosen], artifact: mac.artifact, catalog: mac.configuration))
    }

    func testTheModelIsFreedOnlyWhenNoWorkflowUsesBuiltIn() {
        typealias Workflow = BuiltInUsage.Workflow
        XCTAssertTrue(BuiltInUsage.isUsed(by: [Workflow(isAIEnabled: true, providerName: "Built-in")]))
        XCTAssertTrue(BuiltInUsage.isUsed(by: [Workflow(isAIEnabled: true, providerName: "Gemini"), Workflow(isAIEnabled: true, providerName: "Built-in")]))
        XCTAssertFalse(BuiltInUsage.isUsed(by: [Workflow(isAIEnabled: false, providerName: "Built-in")]), "AI switched off for it")
        XCTAssertFalse(BuiltInUsage.isUsed(by: [Workflow(isAIEnabled: true, providerName: "Ollama")]))
        XCTAssertFalse(BuiltInUsage.isUsed(by: []))
    }
}

/// A runtime that records the deadlines it is given and can hold `prepare` until the test lets it go.
private actor DeadlineRuntime: FormatterRuntime {
    nonisolated let id: FormatterRuntimeID = .llama
    private(set) var prepareDeadline: ContinuousClock.Instant?
    private(set) var prepares: [(RuntimeModelSpec, PromptPrefix)] = []
    private(set) var requests: [GenerationRequest] = []
    var prepareDelay: Duration = .zero
    var finishedPrepares = 0

    func setPrepareDelay(_ delay: Duration) { prepareDelay = delay }

    func prepare(_ spec: RuntimeModelSpec, prefix: PromptPrefix) async throws {
        prepares.append((spec, prefix))
        if prepareDelay > .zero { try await Task.sleep(for: prepareDelay) }
        finishedPrepares += 1
    }

    func prepare(_ spec: RuntimeModelSpec, prefix: PromptPrefix, deadline: ContinuousClock.Instant) async throws {
        prepareDeadline = deadline
        try await prepare(spec, prefix: prefix)
    }

    func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        requests.append(request)
        return GenerationResult(text: "Hello there, how are you doing today.")
    }

    func cancel(_ requestID: UUID) async {}
    func unload() async {}
}

final class BuiltInPreloadAndDeadlineTests: XCTestCase {
    private func installed(_ mac: FakeMac) async throws -> String {
        try mac.addHuggingFaceModel()
        let entries = await BuiltInModels.installed(chosenFiles: [], artifact: mac.artifact, catalog: mac.configuration)
        return try XCTUnwrap(entries.first?.id)
    }

    private func engine(_ runtime: any FormatterRuntime, _ mac: FakeMac) -> BuiltInEngine {
        BuiltInEngine(runtime: runtime, chosenFiles: { [] }, artifact: { mac.artifact }, catalog: { mac.configuration })
    }

    func testRecordingAWorkflowThatUsesBuiltInLoadsItsModelWithTheCleanedTextPrefix() async throws {
        let mac = try FakeMac()
        let id = try await installed(mac)
        let fake = FakeRuntime(returning: "x")
        let task = engine(fake, mac).preloadIfUsed(isEnabled: true, providerName: "Built-in", modelID: id)
        await task?.value
        let prepared = await fake.prepareCalls
        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(prepared.first?.0.modelURL?.lastPathComponent, "gemma-4-E2B-it-Q4_K_M.gguf")
        XCTAssertEqual(prepared.first?.1, try FormatterPipeline.bundled(runtime: fake).prefix)
    }

    func testOtherWorkflowsAndEmptyChoicesLoadNothing() async throws {
        let mac = try FakeMac()
        let id = try await installed(mac)
        let fake = FakeRuntime(returning: "x")
        let engine = engine(fake, mac)
        XCTAssertNil(engine.preloadIfUsed(isEnabled: true, providerName: "Ollama", modelID: id))
        XCTAssertNil(engine.preloadIfUsed(isEnabled: false, providerName: "Built-in", modelID: id))
        XCTAssertNil(engine.preloadIfUsed(isEnabled: true, providerName: nil, modelID: id))
        XCTAssertNil(engine.preloadIfUsed(isEnabled: true, providerName: "Built-in", modelID: nil))
        XCTAssertNil(engine.preloadIfUsed(isEnabled: true, providerName: "Built-in", modelID: ""))
        // A model that is gone is not loaded either; the take will fall back as it does today.
        await engine.preloadIfUsed(isEnabled: true, providerName: "Built-in", modelID: "hf:gone/x.gguf")?.value
        let prepared = await fake.prepareCalls
        XCTAssertTrue(prepared.isEmpty)
    }

    func testAFailedPreloadIsQuietAndTheTakeStillFallsBack() async throws {
        let mac = try FakeMac()
        let id = try await installed(mac)
        let failing = FakeRuntime(id: .llama, prepareError: .failed("could not load")) { _ in throw FormatterRuntimeError.notReady }
        let engine = engine(failing, mac)
        await engine.preloadIfUsed(isEnabled: true, providerName: "Built-in", modelID: id)?.value
        let result = await GuardedCleanup.makeBuiltIn(modelID: id, engine: engine).clean("um so i think we should meet on tuesday at three")
        XCTAssertNotNil(result.fallbackReason)
        XCTAssertTrue(result.text.lowercased().contains("tuesday"))
    }

    func testPreloadDoesNotMakeTheCallerWaitForTheLoad() async throws {
        let mac = try FakeMac()
        let id = try await installed(mac)
        let runtime = DeadlineRuntime()
        await runtime.setPrepareDelay(.milliseconds(500))
        let started = ContinuousClock.now
        let task = engine(runtime, mac).preloadIfUsed(isEnabled: true, providerName: "Built-in", modelID: id)
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(100), "returns before the load is done")
        let finishedEarly = await runtime.finishedPrepares
        XCTAssertEqual(finishedEarly, 0)
        await task?.value
        let finished = await runtime.finishedPrepares
        XCTAssertEqual(finished, 1)
    }

    func testAFreeFormRequestLoadsAndGeneratesUnderOneDeadline() async throws {
        let mac = try FakeMac()
        let id = try await installed(mac)
        let runtime = DeadlineRuntime()
        _ = try await engine(runtime, mac).complete(system: "s", user: "u", modelID: id, timeout: 30)
        let recordedDeadline = await runtime.prepareDeadline
        let prepareDeadline = try XCTUnwrap(recordedDeadline)
        let requests = await runtime.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.deadline, prepareDeadline, "one deadline for both")
        XCTAssertEqual(request.prefixKey, PromptPrefix(messages: [ChatMessage(role: .system, content: "s")]).key)
    }

    func testCleanedTextSpendsTheLoadOutOfTheSameBudgetAsTheGeneration() async throws {
        let mac = try FakeMac()
        let id = try await installed(mac)
        let runtime = DeadlineRuntime()
        await runtime.setPrepareDelay(.milliseconds(300))
        let started = ContinuousClock.now
        _ = await GuardedCleanup.makeBuiltIn(modelID: id, engine: engine(runtime, mac))
            .clean("hello there how are you doing today my friend")
        let recordedDeadline = await runtime.prepareDeadline
        let prepareDeadline = try XCTUnwrap(recordedDeadline)
        let requests = await runtime.requests
        let request = try XCTUnwrap(requests.first)
        // The generation deadline is inside the take's deadline (plus the 0.5 s floor), not a fresh budget on top.
        XCTAssertLessThanOrEqual(request.deadline, prepareDeadline + .milliseconds(600))
        XCTAssertGreaterThan(request.deadline, started)
        XCTAssertEqual(request.prefixKey, try FormatterPipeline.bundled(runtime: runtime).prefix.key)
    }
}

/// A runtime whose `generate` waits until the test lets it go.
private actor HoldRuntime: FormatterRuntime {
    nonisolated let id: FormatterRuntimeID = .llama
    private(set) var unloadCount = 0
    private(set) var generating = false
    private var gate: CheckedContinuation<Void, Never>?

    func prepare(_ spec: RuntimeModelSpec, prefix: PromptPrefix) async throws {}

    func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        generating = true
        await withCheckedContinuation { gate = $0 }
        generating = false
        return GenerationResult(text: "- done")
    }

    func release() { gate?.resume(); gate = nil }
    func cancel(_ requestID: UUID) async {}
    func unload() async { unloadCount += 1 }
}

final class BuiltInUnloadWhileBusyTests: XCTestCase {
    private typealias Workflow = BuiltInUsage.Workflow
    private let none = [Workflow(isAIEnabled: true, providerName: "Gemini")]
    private let usesBuiltIn = [Workflow(isAIEnabled: true, providerName: "Built-in")]

    private func start() async throws -> (BuiltInEngine, HoldRuntime, Task<String, Error>, String) {
        let mac = try FakeMac()
        try mac.addHuggingFaceModel()
        let entries = await BuiltInModels.installed(chosenFiles: [], artifact: mac.artifact, catalog: mac.configuration)
        let id = try XCTUnwrap(entries.first?.id)
        let runtime = HoldRuntime()
        let engine = BuiltInEngine(runtime: runtime, chosenFiles: { [] }, artifact: { mac.artifact }, catalog: { mac.configuration })
        // A Playground run on a workflow that is not set to Built-in is a request like any other.
        let running = Task { try await engine.complete(system: "s", user: "u", modelID: id, timeout: 30) }
        for _ in 0..<300 {
            if await runtime.generating { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let isGenerating = await runtime.generating
        XCTAssertTrue(isGenerating)
        withExtendedLifetime(mac) {}
        return (engine, runtime, running, id)
    }

    func testSavingAWorkflowDoesNotUnloadUnderARequestAndTheUnloadFollowsItsEnd() async throws {
        let (engine, runtime, running, _) = try await start()
        XCTAssertEqual(engine.requestsInFlight, 1)
        engine.applyUsage(workflows: none)
        try await Task.sleep(for: .milliseconds(100))
        var unloads = await runtime.unloadCount
        XCTAssertEqual(unloads, 0, "the run in flight is not cut off")

        await runtime.release()
        let answer = try await running.value
        XCTAssertEqual(answer, "- done", "and it finishes normally")
        for _ in 0..<300 {
            if await runtime.unloadCount > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        unloads = await runtime.unloadCount
        XCTAssertEqual(unloads, 1, "the deferred unload runs once the run has ended")
    }

    func testAWorkflowThatUsesBuiltInAgainCancelsTheDeferredUnload() async throws {
        let (engine, runtime, running, _) = try await start()
        engine.applyUsage(workflows: none)
        engine.applyUsage(workflows: usesBuiltIn)
        await runtime.release()
        _ = try await running.value
        try await Task.sleep(for: .milliseconds(200))
        let unloads = await runtime.unloadCount
        XCTAssertEqual(unloads, 0)
    }

    func testWithNothingInFlightTheUnloadIsImmediateAndOnlyWhenNoWorkflowUsesBuiltIn() async throws {
        let runtime = HoldRuntime()
        let engine = BuiltInEngine(runtime: runtime, chosenFiles: { [] })
        engine.applyUsage(workflows: usesBuiltIn)
        try await Task.sleep(for: .milliseconds(100))
        var unloads = await runtime.unloadCount
        XCTAssertEqual(unloads, 0)
        engine.applyUsage(workflows: none)
        for _ in 0..<300 {
            if await runtime.unloadCount > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        unloads = await runtime.unloadCount
        XCTAssertEqual(unloads, 1)
    }
}

final class SearchWordsTests: XCTestCase {
    func testEveryWordMustMatchInAnyCase() {
        XCTAssertTrue(SearchWords.matches("Ollama · gemma3:4b", query: ""))
        XCTAssertTrue(SearchWords.matches("Ollama · gemma3:4b", query: "OLLAMA gemma"))
        XCTAssertFalse(SearchWords.matches("Ollama · gemma3:4b", query: "ollama qwen"))
        let choices = [
            PlaygroundModelChoice(provider: "Anthropic", model: "claude-haiku-5-5"),
            PlaygroundModelChoice(provider: "Ollama", model: "gemma3:4b"),
            PlaygroundModelChoice(provider: "Built-in", model: "file:/m/g.gguf", title: "gemma-4-E2B-it"),
        ]
        XCTAssertEqual(choices.filter { SearchWords.matches($0.label, query: "gemma") }.map(\.provider), ["Ollama", "Built-in"])
        XCTAssertEqual(choices.filter { SearchWords.matches($0.label, query: "built-in e2b") }.map(\.provider), ["Built-in"])
        XCTAssertEqual(choices.filter { SearchWords.matches($0.label, query: "claude") }.map(\.provider), ["Anthropic"])
    }
}
