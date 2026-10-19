import Combine
import CryptoKit
import XCTest


/// Headless checks for the optional formatter model download: states, resume, checksum, delete. A stub server
/// stands in for Hugging Face; the real file is never fetched.
@MainActor
final class FormatterModelStoreTests: XCTestCase {
    private var root: URL!
    private let content = Data((0..<10_000).map { UInt8($0 % 241) })
    private var cancellables: [AnyCancellable] = []

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func artifact(hash: String? = nil, size: Int64? = nil) -> FormatterModelArtifact {
        FormatterModelArtifact(
            modelName: "test-model",
            displayName: "Test model",
            fileName: "test-Q4_K_M.gguf",
            repository: "example/test-GGUF",
            repositoryRevision: "0123456789abcdef0123456789abcdef01234567",
            expectedFileSize: size ?? Int64(content.count),
            expectedSHA256: hash ?? sha(content),
            licenseName: "Apache-2.0",
            rootDirectory: root
        )
    }

    private func store(
        _ artifact: FormatterModelArtifact,
        freeSpace: Int64 = .max,
        waitForNetwork: @escaping @Sendable () async -> Void = {}
    ) -> FormatterModelStore {
        FormatterModelStore(
            artifact: artifact,
            downloader: ResumableFileDownloader(
                maximumAttempts: 2,
                sessionConfiguration: { StubDownloadServer.configuration() },
                retryDelay: { _ in .zero }
            ),
            availableCapacity: { _ in freeSpace },
            waitForNetwork: waitForNetwork
        )
    }

    private func record(_ store: FormatterModelStore) -> LockedList<FormatterModelDownloadState> {
        let states = LockedList<FormatterModelDownloadState>()
        store.$state.sink { states.append($0) }.store(in: &cancellables)
        return states
    }

    /// Waits for a state that ends a run.
    private func finish(_ store: FormatterModelStore) async throws {
        for _ in 0..<200 {
            switch store.state {
            case .ready, .failed, .notInstalled: if store.isBusy == false { return }
            default: break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("the store did not finish: \(store.state)")
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FormatterModelStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        StubDownloadServer.stop()
        cancellables = []
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testNothingDownloadsUntilStartIsCalled() async throws {
        StubDownloadServer.serve { [content] _ in .init(status: 200, body: content) }
        let store = store(artifact())
        XCTAssertEqual(store.state, .notInstalled)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(StubDownloadServer.receivedRequests.isEmpty)
        XCTAssertNil(store.installedModelFileURL)
    }

    func testTheShippedArtifactIsPinnedAndShowsItsSize() {
        let gemma = FormatterModelArtifact.gemma4E2B(rootDirectory: root)
        XCTAssertEqual(gemma.expectedFileSize, 3_106_738_272)
        XCTAssertEqual(gemma.expectedSHA256, "740185b21d22ceb83a11c3aa62ad5842ef32c70f6096d756bbee85a1e4ec34b8")
        XCTAssertEqual(
            gemma.downloadURL.absoluteString,
            "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/0314792d7f1f7e229411f620751375812bb9faf2/gemma-4-E2B-it-Q4_K_M.gguf"
        )
        XCTAssertTrue(gemma.downloadSizeText.contains("GB"))
        XCTAssertEqual(FormatterModelStore(artifact: gemma).state, .notInstalled)
    }

    func testDownloadVerifiesAndInstalls() async throws {
        StubDownloadServer.serve { [content] _ in .init(status: 200, body: content) }
        let artifact = artifact()
        let store = store(artifact)
        let states = record(store)
        store.start()
        try await finish(store)

        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(store.installedModelFileURL, artifact.modelFileURL)
        XCTAssertEqual(try Data(contentsOf: artifact.modelFileURL), content)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.partialFileURL.path))
        XCTAssertTrue(states.values.contains(.verifying))
        XCTAssertTrue(states.values.contains { if case .downloading = $0 { true } else { false } })

        // A new store on the same folder starts out ready.
        XCTAssertEqual(self.store(artifact).state, .ready)
    }

    func testResumesFromAPartialFile() async throws {
        let artifact = artifact()
        try FileManager.default.createDirectory(at: artifact.modelDirectory, withIntermediateDirectories: true)
        try content.prefix(6_000).write(to: artifact.partialFileURL)
        StubDownloadServer.serve { [content] request in
            StubDownloadServer.rangeHonouringReply(for: request, content: content)
        }
        let store = store(artifact)
        store.start()
        try await finish(store)
        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(StubDownloadServer.receivedRequests.first?.value(forHTTPHeaderField: "Range"), "bytes=6000-")
    }

    func testAWrongHashFailsAndRemovesTheFile() async throws {
        var other = content
        other[0] ^= 0xFF
        StubDownloadServer.serve { _ in .init(status: 200, body: other) }
        let artifact = artifact()
        let store = store(artifact)
        store.start()
        try await finish(store)

        XCTAssertEqual(store.state, .failed(FormatterModelStoreError.checksumMismatch.localizedDescription))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.partialFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.modelFileURL.path))
        XCTAssertNil(store.installedModelFileURL)
    }

    func testAShortFileFails() async throws {
        StubDownloadServer.serve { [content] _ in .init(status: 200, body: content.prefix(9_000)) }
        let artifact = artifact()
        let store = store(artifact)
        store.start()
        try await finish(store)

        guard case .failed = store.state else { return XCTFail("\(store.state)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.modelFileURL.path))
        XCTAssertNil(store.installedModelFileURL)
    }

    func testALostConnectionPausesThenResumesByItself() async throws {
        let calls = LockedList<Int>()
        StubDownloadServer.serve { [content] _ in
            calls.append(1)
            // Both attempts of the first round fail like a dropped network; the round after the pause succeeds.
            if calls.values.count <= 2 { return .init(status: 0, error: URLError(.notConnectedToInternet)) }
            return .init(status: 200, body: content)
        }
        let store = store(artifact())
        let states = record(store)
        store.start()
        try await finish(store)

        XCTAssertTrue(states.values.contains(.paused))
        XCTAssertEqual(store.state, .ready)
    }

    func testTooLittleFreeSpaceFailsBeforeAnyRequest() async throws {
        StubDownloadServer.serve { [content] _ in .init(status: 200, body: content) }
        let store = store(artifact(), freeSpace: 1_000)
        store.start()
        try await finish(store)

        guard case .failed(let message) = store.state else { return XCTFail("\(store.state)") }
        XCTAssertTrue(message.contains("free disk space"))
        XCTAssertTrue(StubDownloadServer.receivedRequests.isEmpty)
    }

    func testDeleteRemovesTheFolderAndTellsTheOwner() async throws {
        StubDownloadServer.serve { [content] _ in .init(status: 200, body: content) }
        let artifact = artifact()
        let store = store(artifact)
        var deleted = false
        store.onModelDeleted = { deleted = true }
        store.start()
        try await finish(store)
        XCTAssertEqual(store.state, .ready)

        store.delete()
        XCTAssertEqual(store.state, .notInstalled)
        XCTAssertTrue(deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.modelDirectory.path))
    }

    func testCancelStopsTheRunAndKeepsThePartialFile() async throws {
        let artifact = artifact()
        let store = FormatterModelStore(
            artifact: artifact,
            downloader: HangingDownloader(),
            availableCapacity: { _ in .max },
            waitForNetwork: {}
        )
        store.start()
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: artifact.partialFileURL.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(store.isBusy)
        store.cancel()
        try await finish(store)

        XCTAssertEqual(store.state, .notInstalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.partialFileURL.path))
    }
}

/// Writes some bytes, then waits until it is cancelled.
private struct HangingDownloader: FormatterModelFileDownloading {
    func download(
        from sourceURL: URL,
        to partialURL: URL,
        expectedByteCount: Int64,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Data(repeating: 1, count: 100).write(to: partialURL)
        progress(0.01)
        try await Task.sleep(for: .seconds(60))
    }

    func sha256(of fileURL: URL) async throws -> String { "" }
}
