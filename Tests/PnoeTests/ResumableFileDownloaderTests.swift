import CryptoKit
import XCTest


/// Headless checks for `ResumableFileDownloader` against a stub server. Nothing leaves the machine.
final class ResumableFileDownloaderTests: XCTestCase {
    private var directory: URL!
    private var partialURL: URL!
    private let content = Data((0..<10_000).map { UInt8($0 % 251) })
    private let source = URL(string: "https://models.example.test/model.bin")!

    private func downloader(maximumAttempts: Int = 3) -> ResumableFileDownloader {
        ResumableFileDownloader(
            maximumAttempts: maximumAttempts,
            sessionConfiguration: { StubDownloadServer.configuration() },
            retryDelay: { _ in .zero }
        )
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResumableFileDownloaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        partialURL = directory.appendingPathComponent("model.bin.partial")
    }

    override func tearDownWithError() throws {
        StubDownloadServer.stop()
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func run(_ downloader: ResumableFileDownloader) async throws -> [Double] {
        let progress = LockedList<Double>()
        try await downloader.download(
            from: source,
            to: partialURL,
            expectedByteCount: Int64(content.count),
            progress: { progress.append($0) }
        )
        return progress.values
    }

    func testFreshDownloadWritesTheWholeFileAndReportsProgress() async throws {
        StubDownloadServer.serve { [content] _ in .init(status: 200, body: content) }
        let progress = try await run(downloader())
        XCTAssertEqual(try Data(contentsOf: partialURL), content)
        XCTAssertEqual(progress.last, 1)
        XCTAssertNil(StubDownloadServer.receivedRequests.first?.value(forHTTPHeaderField: "Range"))
    }

    func testResumesFromTheBytesAlreadyOnDisk() async throws {
        try content.prefix(4_000).write(to: partialURL)
        StubDownloadServer.serve { [content] request in
            StubDownloadServer.rangeHonouringReply(for: request, content: content)
        }
        _ = try await run(downloader())
        XCTAssertEqual(StubDownloadServer.receivedRequests.first?.value(forHTTPHeaderField: "Range"), "bytes=4000-")
        XCTAssertEqual(try Data(contentsOf: partialURL), content)
    }

    func testAServerThatIgnoresRangeRestartsInsteadOfAppendingDuplicates() async throws {
        try Data(repeating: 0xFF, count: 4_000).write(to: partialURL)
        StubDownloadServer.serve { [content] _ in .init(status: 200, body: content) }
        _ = try await run(downloader())
        XCTAssertEqual(StubDownloadServer.receivedRequests.first?.value(forHTTPHeaderField: "Range"), "bytes=4000-")
        XCTAssertEqual(try Data(contentsOf: partialURL), content)
    }

    func testAWrongContentRangeDropsThePartialFileAndStartsOver() async throws {
        try content.prefix(4_000).write(to: partialURL)
        let calls = LockedList<Int>()
        StubDownloadServer.serve { [content] request in
            calls.append(1)
            if calls.values.count == 1 {
                return .init(status: 206, headers: ["Content-Range": "bytes 0-9999/10000"], body: content)
            }
            return StubDownloadServer.rangeHonouringReply(for: request, content: content)
        }
        _ = try await run(downloader())
        XCTAssertEqual(try Data(contentsOf: partialURL), content)
        XCTAssertNil(StubDownloadServer.receivedRequests.last?.value(forHTTPHeaderField: "Range"))
    }

    func testAShortFileFailsAfterTheRetriesAndKeepsTheBytes() async {
        StubDownloadServer.serve { [content] _ in .init(status: 200, body: content.prefix(9_000)) }
        do {
            _ = try await run(downloader(maximumAttempts: 2))
            XCTFail("a short file must not count as downloaded")
        } catch let error as ResumableFileDownloadError {
            guard case .incompleteDownload(let received, let expected) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(received, 9_000)
            XCTAssertEqual(expected, 10_000)
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(StubDownloadServer.receivedRequests.count, 2)
    }

    func testAnHTTPErrorIsRetriedThenThrown() async {
        StubDownloadServer.serve { _ in .init(status: 503) }
        do {
            _ = try await run(downloader(maximumAttempts: 3))
            XCTFail("expected an HTTP error")
        } catch let error as ResumableFileDownloadError {
            guard case .httpStatus(503) = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(StubDownloadServer.receivedRequests.count, 3)
    }

    func testANotFoundIsNotRetried() async {
        StubDownloadServer.serve { _ in .init(status: 404) }
        do {
            _ = try await run(downloader())
            XCTFail("expected an HTTP error")
        } catch {
            XCTAssertEqual(StubDownloadServer.receivedRequests.count, 1)
        }
    }

    func testAnOversizedPartialFileIsDeletedBeforeTheRequest() async throws {
        try Data(repeating: 1, count: 20_000).write(to: partialURL)
        StubDownloadServer.serve { [content] request in
            StubDownloadServer.rangeHonouringReply(for: request, content: content)
        }
        _ = try await run(downloader())
        XCTAssertNil(StubDownloadServer.receivedRequests.first?.value(forHTTPHeaderField: "Range"))
        XCTAssertEqual(try Data(contentsOf: partialURL), content)
    }

    func testACompletePartialFileMakesNoRequest() async throws {
        try content.write(to: partialURL)
        StubDownloadServer.serve { _ in .init(status: 500) }
        _ = try await run(downloader())
        XCTAssertTrue(StubDownloadServer.receivedRequests.isEmpty)
    }

    func testSHA256MatchesCryptoKit() async throws {
        try content.write(to: partialURL)
        let expected = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let actual = try await ResumableFileDownloader.sha256(of: partialURL)
        XCTAssertEqual(actual, expected)
    }
}

/// A list several threads append to.
final class LockedList<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []
    func append(_ element: Element) { lock.withLock { storage.append(element) } }
    var values: [Element] { lock.withLock { storage } }
}
