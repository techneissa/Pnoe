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
        // An MLX folder and a plain text file are not models for this engine.
        try mac.write("pub/mlx-4bit/config.json", #"{"quantization":{"bits":4}}"#, under: mac.lmStudio)
        try mac.write("pub/mlx-4bit/model.safetensors", "x", under: mac.lmStudio)
        try mac.write("pub/notes/README.md", "x", under: mac.lmStudio)

        let entries = await BuiltInModels.installed(chosenFiles: [chosen], artifact: mac.artifact, catalog: mac.configuration)
        XCTAssertEqual(
            Set(entries.map(\.source)), [.huggingFaceCache, .lmStudio, .ollamaStore, .userChosen])
        XCTAssertEqual(entries.count, 4)
        XCTAssertTrue(entries.allSatisfy { $0.kind == .gguf && $0.spec.modelURL != nil })
        XCTAssertTrue(entries.contains { $0.displayName == "gemma3:4b" && $0.source == .ollamaStore })
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

    func testAStoredChoiceStaysWhileItIsInstalledAndFallsBackWhenItIsGone() {
        let a = entry("gemma-3-4b-it", gigabytes: 2.5)
        let b = entry("Qwen3-4B", gigabytes: 4.2)
        XCTAssertEqual(BuiltInModels.selection(stored: b.id, installed: [a, b]), b.id)
        XCTAssertEqual(BuiltInModels.selection(stored: "gone", installed: [a, b]), a.id)
        XCTAssertEqual(BuiltInModels.selection(stored: nil, installed: [a, b]), a.id)
        XCTAssertNil(BuiltInModels.selection(stored: "gone", installed: []))
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
        XCTAssertFalse(Visibility.isVisible(installedCount: 0, state: .ready))
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
