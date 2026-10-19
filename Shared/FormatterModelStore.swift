import Foundation
import Network
import os

enum FormatterModelDownloadState: Equatable, Sendable {
    case notInstalled
    case downloading(fraction: Double)
    /// The network dropped. The download resumes by itself when it is back; Cancel stops it.
    case paused
    case verifying
    case ready
    case failed(String)
}

/// The two jobs the store needs from a downloader, so tests can swap it.
protocol FormatterModelFileDownloading: Sendable {
    func download(
        from sourceURL: URL,
        to partialURL: URL,
        expectedByteCount: Int64,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws

    func sha256(of fileURL: URL) async throws -> String
}

extension ResumableFileDownloader: FormatterModelFileDownloading {
    func download(
        from sourceURL: URL,
        to partialURL: URL,
        expectedByteCount: Int64,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await download(
            from: sourceURL,
            to: partialURL,
            expectedByteCount: expectedByteCount,
            progress: progress,
            onRetry: { _, _ in }
        )
    }

    func sha256(of fileURL: URL) async throws -> String {
        try await Self.sha256(of: fileURL)
    }
}

enum FormatterModelStoreError: LocalizedError, Equatable {
    case notEnoughSpace(needed: Int64)
    case checksumMismatch
    case wrongSize

    var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let needed):
            let text = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
            return "Not enough free disk space. The download needs \(text) free."
        case .checksumMismatch:
            return "The downloaded file did not match its checksum and was removed."
        case .wrongSize:
            return "The downloaded file has the wrong size and was removed."
        }
    }
}

/// Downloads and holds the optional formatter model. Nothing starts until `start()` is called, which the
/// settings button does after showing `artifact.downloadSizeText`. Models the Mac already has (Ollama, the
/// Hugging Face cache, LM Studio) are found by `FormatterModels` and never copied here.
@MainActor
final class FormatterModelStore: ObservableObject {
    @Published private(set) var state: FormatterModelDownloadState

    let artifact: FormatterModelArtifact
    var onModelDeleted: (() -> Void)?

    private let downloader: any FormatterModelFileDownloading
    private let availableCapacity: @Sendable (URL) -> Int64
    private let waitForNetwork: @Sendable () async -> Void
    private var task: Task<Void, Never>?
    /// Which run owns `task` and `state`. A run that is no longer current (it was cancelled or deleted while
    /// unwinding) changes neither.
    private var currentRun: UUID?
    /// The run `delete()` cancelled; the next run waits for it to finish before it touches the folder.
    private var unwindingTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.techneissa.pnoe", category: "FormatterModelStore")

    init(
        artifact: FormatterModelArtifact = .gemma4E2B(),
        downloader: any FormatterModelFileDownloading = ResumableFileDownloader(),
        availableCapacity: @escaping @Sendable (URL) -> Int64 = FormatterModelStore.volumeAvailableCapacity,
        waitForNetwork: @escaping @Sendable () async -> Void = FormatterModelStore.waitUntilOnline
    ) {
        self.artifact = artifact
        self.downloader = downloader
        self.availableCapacity = availableCapacity
        self.waitForNetwork = waitForNetwork
        self.state = artifact.modelFileIsValid ? .ready : .notInstalled
    }

    /// The file a runtime loads, once the model is ready.
    var installedModelFileURL: URL? {
        state == .ready ? artifact.installedModelFileURL : nil
    }

    var isBusy: Bool {
        switch state {
        case .downloading, .paused, .verifying: true
        case .notInstalled, .ready, .failed: false
        }
    }

    /// Re-reads the disk, for example after the user deleted the folder in Finder.
    func refresh() {
        guard !isBusy else { return }
        state = artifact.modelFileIsValid ? .ready : .notInstalled
    }

    /// Starts or resumes the download. Does nothing while one runs or the model is ready.
    func start() {
        guard task == nil, state != .ready else { return }
        let run = UUID()
        let previous = unwindingTask
        currentRun = run
        state = .downloading(fraction: 0)
        task = Task { [weak self] in
            await previous?.value
            guard let self, self.currentRun == run else { return }
            await self.run(run)
            if self.currentRun == run {
                self.currentRun = nil
                self.task = nil
            }
        }
    }

    /// Stops the download. The partial file stays so the next `start()` continues from it; `delete()` removes it.
    func cancel() {
        task?.cancel()
    }

    /// Removes the folder (model, partial file and marker). The owner turns the feature off in `onModelDeleted`.
    func delete() {
        task?.cancel()
        if let task { unwindingTask = task }
        task = nil
        currentRun = nil
        artifact.removeInstalledFiles()
        state = .notInstalled
        onModelDeleted?()
    }

    // MARK: Download

    private func run(_ run: UUID) async {
        let artifact = artifact
        do {
            try FileManager.default.createDirectory(at: artifact.modelDirectory, withIntermediateDirectories: true)
            try checkFreeSpace()

            while true {
                do {
                    try await downloader.download(
                        from: artifact.downloadURL,
                        to: artifact.partialFileURL,
                        expectedByteCount: artifact.expectedFileSize,
                        progress: { [weak self] fraction in
                            Task { @MainActor [weak self] in self?.updateProgress(fraction, run: run) }
                        }
                    )
                    break
                } catch where Self.isConnectionLoss(error) && !Task.isCancelled {
                    logger.notice("Formatter model download paused: \(error.localizedDescription, privacy: .public)")
                    set(.paused, run)
                    await waitForNetwork()
                    try Task.checkCancellation()
                    set(.downloading(fraction: progressFraction()), run)
                }
            }
            try Task.checkCancellation()

            set(.verifying, run)
            try await verifyAndInstall()
            set(.ready, run)
            logger.notice("Formatter model installed")
        } catch is CancellationError {
            logger.notice("Formatter model download cancelled")
            set(.notInstalled, run)
        } catch let error as URLError where error.code == .cancelled {
            set(.notInstalled, run)
        } catch {
            logger.error("Formatter model download failed: \(error.localizedDescription, privacy: .public)")
            set(.failed(error.localizedDescription), run)
        }
    }

    private func verifyAndInstall() async throws {
        let artifact = artifact
        guard ResumableFileDownloader.fileSize(at: artifact.partialFileURL) == artifact.expectedFileSize else {
            try? FileManager.default.removeItem(at: artifact.partialFileURL)
            throw FormatterModelStoreError.wrongSize
        }

        let downloader = downloader
        let partialURL = artifact.partialFileURL
        let checksumTask = Task.detached(priority: .utility) {
            try await downloader.sha256(of: partialURL)
        }
        let checksum = try await withTaskCancellationHandler {
            try await checksumTask.value
        } onCancel: {
            checksumTask.cancel()
        }
        try Task.checkCancellation()
        guard checksum == artifact.expectedSHA256 else {
            try? FileManager.default.removeItem(at: artifact.partialFileURL)
            throw FormatterModelStoreError.checksumMismatch
        }

        // Marker first, model file second: the install shows as complete only once the model file is in place.
        try artifact.expectedSHA256.write(to: artifact.checksumFileURL, atomically: true, encoding: .utf8)
        do {
            try? FileManager.default.removeItem(at: artifact.modelFileURL)
            try FileManager.default.moveItem(at: artifact.partialFileURL, to: artifact.modelFileURL)
            guard artifact.modelFileIsValid else { throw CocoaError(.fileReadCorruptFile) }
        } catch {
            try? FileManager.default.removeItem(at: artifact.modelFileURL)
            try? FileManager.default.removeItem(at: artifact.checksumFileURL)
            throw error
        }
    }

    private func checkFreeSpace() throws {
        let alreadyThere = ResumableFileDownloader.fileSize(at: artifact.partialFileURL)
        let needed = max(FormatterModelArtifact.minimumFreeBytes, artifact.expectedFileSize - alreadyThere)
        guard availableCapacity(artifact.modelDirectory) >= needed else {
            throw FormatterModelStoreError.notEnoughSpace(needed: needed)
        }
    }

    /// Sets the state only if `run` is still the current run.
    private func set(_ newState: FormatterModelDownloadState, _ run: UUID) {
        guard currentRun == run else { return }
        state = newState
    }

    private func updateProgress(_ fraction: Double, run: UUID) {
        guard currentRun == run, fraction.isFinite, (0...1).contains(fraction) else { return }
        switch state {
        case .downloading(let current):
            // Progress only moves forward, except the reset to 0 after a restart from byte 0.
            guard fraction == 0 || fraction > current else { return }
            state = .downloading(fraction: fraction)
        default:
            break
        }
    }

    private func progressFraction() -> Double {
        guard artifact.expectedFileSize > 0 else { return 0 }
        let bytes = ResumableFileDownloader.fileSize(at: artifact.partialFileURL)
        return min(max(Double(bytes) / Double(artifact.expectedFileSize), 0), 1)
    }

    private static func isConnectionLoss(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost,
            .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
            return true
        default:
            return false
        }
    }

    // MARK: Defaults

    nonisolated static func volumeAvailableCapacity(at directory: URL) -> Int64 {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Waits at least 5 seconds, then until the system reports a usable network path.
    nonisolated static func waitUntilOnline() async {
        let monitor = NWPathMonitor()
        let statuses = AsyncStream<NWPath.Status> { continuation in
            monitor.pathUpdateHandler = { continuation.yield($0.status) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "com.techneissa.pnoe.formatter-model-network"))
        }
        try? await Task.sleep(for: .seconds(5))
        for await status in statuses where status == .satisfied {
            return
        }
    }
}
