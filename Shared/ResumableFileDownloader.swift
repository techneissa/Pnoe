import CryptoKit
import Foundation

enum ResumableFileDownloadError: LocalizedError {
    case httpStatus(Int)
    case invalidRangeResponse
    case incompleteDownload(received: Int64, expected: Int64)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let statusCode):
            return "Model download returned HTTP status \(statusCode)."
        case .invalidRangeResponse:
            return "The model server returned an invalid resume response."
        case .incompleteDownload(let received, let expected):
            return "The model download ended after \(received) of \(expected) bytes."
        }
    }
}

final class ResumableFileDownloadOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destinationURL: URL
    private let expectedByteCount: Int64
    private let progressHandler: @Sendable (Double) -> Void
    private let sessionConfiguration: URLSessionConfiguration
    private let lock = NSLock()
    private var session: URLSession?
    private var fileHandle: FileHandle?
    private var continuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var response: HTTPURLResponse?
    private var totalBytesWritten: Int64 = 0
    private var lastReportedFraction = 0.0
    private var isCancelled = false
    private var isCompleted = false

    init(
        destinationURL: URL,
        expectedByteCount: Int64,
        sessionConfiguration: URLSessionConfiguration = .default,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) {
        self.destinationURL = destinationURL
        self.expectedByteCount = expectedByteCount
        self.sessionConfiguration = sessionConfiguration
        self.progressHandler = progressHandler
    }

    func start(from sourceURL: URL) async throws -> HTTPURLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumeOffset = ResumableFileDownloader.fileSize(at: destinationURL)
                var request = URLRequest(url: sourceURL)
                if resumeOffset > 0 {
                    request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
                }

                let session = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)

                let shouldStart = lock.withLock {
                    guard !isCancelled, !isCompleted else { return false }
                    self.session = session
                    self.continuation = continuation
                    totalBytesWritten = resumeOffset
                    return true
                }

                if shouldStart {
                    reportProgress(for: resumeOffset)
                    task.resume()
                } else {
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(with: .failure(URLError(.badServerResponse)))
            return
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            completionHandler(.cancel)
            finish(with: .failure(ResumableFileDownloadError.httpStatus(httpResponse.statusCode)))
            return
        }

        let requestedOffset = lock.withLock { totalBytesWritten }
        let shouldAppend: Bool
        if requestedOffset > 0 && httpResponse.statusCode == 206 {
            guard Self.contentRange(in: httpResponse, startsAt: requestedOffset) else {
                completionHandler(.cancel)
                finish(with: .failure(ResumableFileDownloadError.invalidRangeResponse))
                return
            }
            shouldAppend = true
        } else {
            // A 200 response means Range was ignored, so restart instead of appending duplicates.
            shouldAppend = false
        }

        do {
            let handle = try Self.openFile(at: destinationURL, appending: shouldAppend)
            lock.withLock {
                self.response = httpResponse
                fileHandle = handle
                if !shouldAppend {
                    totalBytesWritten = 0
                    lastReportedFraction = 0
                }
            }
            if requestedOffset > 0 && !shouldAppend {
                progressHandler(0)
            }
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            finish(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            let progress = try lock.withLock { () throws -> Double? in
                guard !isCompleted, let fileHandle else { return nil }
                try fileHandle.write(contentsOf: data)
                totalBytesWritten += Int64(data.count)
                return progressToReport(for: totalBytesWritten)
            }
            if let progress {
                progressHandler(progress)
            }
        } catch {
            dataTask.cancel()
            finish(with: .failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(with: .failure(error))
            return
        }

        let completion = lock.withLock { (response: self.response, byteCount: totalBytesWritten) }
        guard let response = completion.response else {
            finish(with: .failure(URLError(.badServerResponse)))
            return
        }
        guard completion.byteCount == expectedByteCount else {
            finish(
                with: .failure(
                    ResumableFileDownloadError.incompleteDownload(
                        received: completion.byteCount,
                        expected: expectedByteCount
                    )
                )
            )
            return
        }
        reportProgress(for: completion.byteCount)
        finish(with: .success(response))
    }

    private func finish(with result: Result<HTTPURLResponse, Error>) {
        let resolution = lock.withLock {
            guard !isCompleted else {
                return (
                    nil as CheckedContinuation<HTTPURLResponse, Error>?,
                    nil as URLSession?,
                    nil as FileHandle?
                )
            }

            isCompleted = true
            let continuation = self.continuation
            let session = self.session
            let fileHandle = self.fileHandle
            self.continuation = nil
            self.session = nil
            self.fileHandle = nil
            return (continuation, session, fileHandle)
        }

        try? resolution.2?.close()
        resolution.1?.finishTasksAndInvalidate()
        resolution.0?.resume(with: result)
    }

    private func cancel() {
        let session = lock.withLock {
            isCancelled = true
            return self.session
        }
        session?.invalidateAndCancel()
    }

    private func reportProgress(for byteCount: Int64) {
        let progress = lock.withLock { progressToReport(for: byteCount) }
        if let progress {
            progressHandler(progress)
        }
    }

    private func progressToReport(for byteCount: Int64) -> Double? {
        guard expectedByteCount > 0 else { return nil }
        let fraction = min(max(Double(byteCount) / Double(expectedByteCount), 0), 1)
        guard fraction == 1 || fraction - lastReportedFraction >= 0.005 else { return nil }
        lastReportedFraction = fraction
        return fraction
    }

    private static func openFile(at url: URL, appending: Bool) throws -> FileHandle {
        if !appending {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        if appending {
            try handle.seekToEnd()
        }
        return handle
    }

    private static func contentRange(in response: HTTPURLResponse, startsAt offset: Int64) -> Bool {
        guard let contentRange = response.value(forHTTPHeaderField: "Content-Range")?.lowercased() else {
            return false
        }
        return contentRange.hasPrefix("bytes \(offset)-")
    }

}


/// Downloads one file with HTTP Range resume, retries and a SHA-256 helper. Shared by the transcription model
/// manager and the formatter model store. The caller owns what happens before (free space, the folder) and
/// after (checksum, rename).
struct ResumableFileDownloader: Sendable {
    var maximumAttempts = 3
    var sessionConfiguration: @Sendable () -> URLSessionConfiguration = { .default }
    /// How long to wait before attempt `n + 1`, after attempt `n` failed.
    var retryDelay: @Sendable (Int) -> Duration = { .seconds($0) }

    /// Fetches `sourceURL` into `partialURL`, continuing from the bytes already there. Returns when the file has
    /// `expectedByteCount` bytes (checksum is the caller's job). A file that is already longer than expected is
    /// deleted first; one that is already complete is left alone.
    func download(
        from sourceURL: URL,
        to partialURL: URL,
        expectedByteCount: Int64,
        progress: @escaping @Sendable (Double) -> Void,
        onRetry: @Sendable (_ attempt: Int, _ error: Error) -> Void
    ) async throws {
        if Self.fileSize(at: partialURL) > expectedByteCount {
            try? FileManager.default.removeItem(at: partialURL)
        }
        guard Self.fileSize(at: partialURL) < expectedByteCount else { return }

        var attempt = 1

        while true {
            try Task.checkCancellation()

            let operation = ResumableFileDownloadOperation(
                destinationURL: partialURL,
                expectedByteCount: expectedByteCount,
                sessionConfiguration: sessionConfiguration(),
                progressHandler: progress
            )

            do {
                _ = try await operation.start(from: sourceURL)
                return
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }

                if let downloadError = error as? ResumableFileDownloadError,
                    case .invalidRangeResponse = downloadError
                {
                    try? FileManager.default.removeItem(at: partialURL)
                    progress(0)
                } else if Self.fileSize(at: partialURL) > expectedByteCount {
                    try? FileManager.default.removeItem(at: partialURL)
                    progress(0)
                }

                guard attempt < maximumAttempts, Self.isRetryable(error) else {
                    throw error
                }

                onRetry(attempt, error)
                try await Task.sleep(for: retryDelay(attempt))
                attempt += 1
            }
        }
    }

    /// Size of a regular file, 0 when the file is missing or not a regular file.
    static func fileSize(at url: URL) -> Int64 {
        // URL caches resource values, so a file deleted or rewritten since the last read would report its old size.
        var url = url
        url.removeAllCachedResourceValues()
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { return 0 }
        return Int64(values?.fileSize ?? 0)
    }

    static func isRetryable(_ error: Error) -> Bool {
        if let downloadError = error as? ResumableFileDownloadError {
            switch downloadError {
            case .invalidRangeResponse, .incompleteDownload:
                return true
            case .httpStatus(let statusCode):
                return statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
            }
        }

        // Retry non-cancellation URL failures while retaining downloaded bytes.
        return error is URLError
    }

    static func sha256(of fileURL: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 8 * 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
