import XCTest

final class WhisperKitCatalogTests: XCTestCase {
    private var root: URL!
    private var storage: WhisperKitStorage!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperKitCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        storage = WhisperKitStorage(base: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Catalog entries

    func testCatalogListsLargeV3TurboSmallAndBase() {
        XCTAssertEqual(
            WhisperKitCatalog.models.map(\.name),
            ["whisperkit-large-v3-turbo", "whisperkit-small", "whisperkit-base"])
    }

    func testNamesAndVariantsAreUnique() {
        XCTAssertEqual(Set(WhisperKitCatalog.models.map(\.name)).count, WhisperKitCatalog.models.count)
        XCTAssertEqual(Set(WhisperKitCatalog.models.map(\.variant)).count, WhisperKitCatalog.models.count)
    }

    func testEveryVariantIsAnArgmaxFolderAndHasATokenizer() {
        for spec in WhisperKitCatalog.models {
            XCTAssertTrue(spec.variant.hasPrefix("openai_whisper-"), spec.variant)
            XCTAssertTrue(spec.tokenizerRepository.hasPrefix("openai/whisper-"), spec.tokenizerRepository)
            XCTAssertEqual(spec.tokenizerRevision.count, 40)
            XCTAssertGreaterThan(spec.modelBytes, 100_000_000)
            XCTAssertGreaterThan(spec.tokenizerBytes, 0)
        }
        XCTAssertEqual(WhisperKitCatalog.revision.count, 40)
    }

    func testSizeIsShownBeforeDownloadAndIncludesTheTokenizer() {
        let turbo = WhisperKitCatalog.largeV3Turbo
        XCTAssertEqual(turbo.totalBytes, 645_668_913 + 2_764_732)
        XCTAssertEqual(turbo.formattedSize, "648 MB")
        XCTAssertEqual(WhisperKitCatalog.small.formattedSize, "220 MB")
        XCTAssertEqual(WhisperKitCatalog.base.formattedSize, "149 MB")
    }

    func testFormattedSizeSwitchesToGigabytes() {
        XCTAssertEqual(WhisperKitCatalog.formattedSize(75_000_000), "75 MB")
        XCTAssertEqual(WhisperKitCatalog.formattedSize(1_500_000_000), "1.5 GB")
    }

    func testLookupByName() {
        XCTAssertEqual(WhisperKitCatalog.spec(named: "whisperkit-small"), WhisperKitCatalog.small)
        XCTAssertNil(WhisperKitCatalog.spec(named: "ggml-small"))
    }

    // MARK: Storage layout

    func testModelsLiveUnderTheAppSupportWhisperKitFolder() {
        let path = WhisperKitStorage.defaultBase.path
        XCTAssertTrue(path.hasSuffix("com.techneissa.Pnoe/WhisperKit"), path)
    }

    func testPathsFollowTheDownloaderLayout() {
        let spec = WhisperKitCatalog.small
        XCTAssertEqual(
            storage.modelFolder(for: spec).path,
            root.path + "/models/argmaxinc/whisperkit-coreml/openai_whisper-small_216MB")
        XCTAssertEqual(storage.tokenizerFolder(for: spec).path, root.path + "/models/openai/whisper-small")
        XCTAssertEqual(
            storage.downloadCacheFolder(for: spec).path,
            root.path + "/models/argmaxinc/whisperkit-coreml/.cache/huggingface/download/openai_whisper-small_216MB")
    }

    // MARK: Install state

    /// Lays down the files a finished download leaves, with filler bytes totalling `modelBytes`.
    private func install(_ spec: WhisperKitModelSpec, withBytes bytes: Int64? = nil) throws {
        let folder = storage.modelFolder(for: spec)
        for component in WhisperKitCatalog.requiredComponents {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent(component), withIntermediateDirectories: true)
        }
        let payload = bytes ?? spec.modelBytes
        try Data(count: Int(payload)).write(to: folder.appendingPathComponent("AudioEncoder.mlmodelc/weight.bin"))
        let tokenizer = storage.tokenizerFolder(for: spec)
        try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: tokenizer.appendingPathComponent("tokenizer.json"))
    }

    private func smallSpec(modelBytes: Int64) -> WhisperKitModelSpec {
        WhisperKitModelSpec(
            name: "whisperkit-test", displayName: "Test", description: "", variant: "openai_whisper-test",
            modelBytes: modelBytes, tokenizerRepository: "openai/whisper-test", tokenizerRevision: "x",
            tokenizerBytes: 2, isMultilingual: true, speed: 0.5, accuracy: 0.5, ramUsage: 0.1)
    }

    func testNothingIsInstalledBeforeADownload() {
        for spec in WhisperKitCatalog.models {
            XCTAssertFalse(storage.isInstalled(spec))
        }
    }

    func testFilesWithoutTheCompletionMarkerAreNotInstalled() throws {
        let spec = smallSpec(modelBytes: 1_000)
        try install(spec)
        XCTAssertFalse(storage.isInstalled(spec))
    }

    func testMarkInstalledChecksTheByteCount() throws {
        let spec = smallSpec(modelBytes: 1_000)
        try install(spec, withBytes: 999)
        XCTAssertThrowsError(try storage.markInstalled(spec))
        XCTAssertFalse(storage.isInstalled(spec))

        try install(spec, withBytes: 1_000)
        try storage.markInstalled(spec)
        XCTAssertTrue(storage.isInstalled(spec))
    }

    func testInstalledNeedsTheTokenizerAndEveryComponent() throws {
        let spec = smallSpec(modelBytes: 1_000)
        try install(spec)
        try storage.markInstalled(spec)
        XCTAssertTrue(storage.isInstalled(spec))

        try FileManager.default.removeItem(at: storage.tokenizerFolder(for: spec))
        XCTAssertFalse(storage.isInstalled(spec))

        try install(spec)
        XCTAssertTrue(storage.isInstalled(spec))
        try FileManager.default.removeItem(
            at: storage.modelFolder(for: spec).appendingPathComponent("TextDecoder.mlmodelc"))
        XCTAssertFalse(storage.isInstalled(spec))
    }

    // MARK: Delete

    func testDeleteRemovesOnlyItsOwnFiles() throws {
        let first = smallSpec(modelBytes: 1_000)
        let other = WhisperKitModelSpec(
            name: "whisperkit-other", displayName: "Other", description: "", variant: "openai_whisper-other",
            modelBytes: 1_000, tokenizerRepository: "openai/whisper-other", tokenizerRevision: "x",
            tokenizerBytes: 2, isMultilingual: true, speed: 0.5, accuracy: 0.5, ramUsage: 0.1)
        try install(first)
        try install(other)
        try storage.markInstalled(first)
        try storage.markInstalled(other)
        let cache = storage.downloadCacheFolder(for: first)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: cache.appendingPathComponent("x.incomplete"))
        let otherCache = storage.downloadCacheFolder(for: other)
        try FileManager.default.createDirectory(at: otherCache, withIntermediateDirectories: true)

        storage.deleteFiles(for: first, installedSpecs: [first, other])

        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.modelFolder(for: first).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.tokenizerFolder(for: first).path))
        XCTAssertTrue(storage.isInstalled(other))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherCache.path))
    }

    func testDeleteKeepsATokenizerAnotherModelStillUses() throws {
        let first = smallSpec(modelBytes: 1_000)
        let sibling = WhisperKitModelSpec(
            name: "whisperkit-test-b", displayName: "B", description: "", variant: "openai_whisper-test_b",
            modelBytes: 1_000, tokenizerRepository: first.tokenizerRepository, tokenizerRevision: "x",
            tokenizerBytes: 2, isMultilingual: true, speed: 0.5, accuracy: 0.5, ramUsage: 0.1)
        try install(first)
        try install(sibling)
        try storage.markInstalled(first)
        try storage.markInstalled(sibling)

        storage.deleteFiles(for: first, installedSpecs: [first, sibling])

        XCTAssertFalse(storage.isInstalled(first))
        XCTAssertTrue(storage.isInstalled(sibling))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.tokenizerFolder(for: sibling).path))
    }

    func testDeleteLeavesUnrelatedFilesInTheBaseAlone() throws {
        let spec = smallSpec(modelBytes: 1_000)
        try install(spec)
        try storage.markInstalled(spec)
        let unrelated = root.appendingPathComponent("models/argmaxinc/whisperkit-coreml/other-file.txt")
        try Data("keep".utf8).write(to: unrelated)

        storage.deleteFiles(for: spec, installedSpecs: [spec])

        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
}
