import AppKit
import Foundation
import os

struct TranscribeCppDownloadStatus: Sendable {
    let fractionCompleted: Double
    let message: String
    let isIndeterminate: Bool
}

@MainActor
final class TranscribeCppModelManager: ObservableObject {
    static let shared = TranscribeCppModelManager()
    
    @Published private var downloadStatuses: [String: TranscribeCppDownloadStatus] = [:]

    var onModelDeleted: ((String) -> Void)?
    var onModelsChanged: (() -> Void)?

    private var activeDownloadIDs: [String: UUID] = [:]
    private var activeDownloadTasks: [String: Task<Void, Never>] = [:]
    private let logger = Logger(
        subsystem: "com.techneissa.pnoe",
        category: "TranscribeCppModelManager"
    )

    private init() {}

    func isModelDownloaded(_ model: TranscribeCppModel) -> Bool {
        isModelDownloaded(named: model.name)
    }

    func isModelDownloaded(named modelName: String) -> Bool {
        TranscribeCppModelCatalog.artifact(for: modelName)?.installedModelFileURL != nil
    }

    func isModelDownloading(_ model: TranscribeCppModel) -> Bool {
        activeDownloadIDs[model.name] != nil
    }

    func downloadStatus(for model: TranscribeCppModel) -> TranscribeCppDownloadStatus? {
        downloadStatuses[model.name]
    }

    func startDownload(_ model: TranscribeCppModel) {
        guard activeDownloadTasks[model.name] == nil else { return }
        activeDownloadTasks[model.name] = Task { [weak self] in
            guard let self else { return }
            await self.downloadModel(model)
            self.activeDownloadTasks[model.name] = nil
        }
    }

    func cancelDownload(_ model: TranscribeCppModel) {
        activeDownloadTasks[model.name]?.cancel()
    }

    private func downloadModel(_ model: TranscribeCppModel) async {
        guard
            let artifact = TranscribeCppModelCatalog.artifact(for: model.name),
            activeDownloadIDs[model.name] == nil,
            !isModelDownloaded(model)
        else {
            return
        }

        let downloadID = UUID()
        activeDownloadIDs[model.name] = downloadID
        downloadStatuses[model.name] = TranscribeCppDownloadStatus(
            fractionCompleted: 0,
            message: String(localized: "Downloading..."),
            isIndeterminate: false
        )

        defer {
            if activeDownloadIDs[model.name] == downloadID {
                activeDownloadIDs[model.name] = nil
                downloadStatuses[model.name] = nil
                onModelsChanged?()
            }
        }

        let partialURL = artifact.modelDirectory.appendingPathComponent("\(artifact.fileName).partial")
        let modelName = model.name

        do {
            try FileManager.default.createDirectory(at: artifact.modelDirectory, withIntermediateDirectories: true)
            try await downloadArtifact(
                artifact,
                to: partialURL,
                modelName: modelName,
                downloadID: downloadID
            )
            try Task.checkCancellation()
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: partialURL)
            logger.notice("\(model.displayName, privacy: .public) download cancelled")
            return
        } catch {
            reportFailure(error, for: model)
            return
        }

        downloadStatuses[model.name] = TranscribeCppDownloadStatus(
            fractionCompleted: 1,
            message: String(localized: "Verifying..."),
            isIndeterminate: true
        )

        do {
            guard ResumableFileDownloader.fileSize(at: partialURL) == artifact.expectedFileSize else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let checksumTask = Task.detached(priority: .utility) {
                try await ResumableFileDownloader.sha256(of: partialURL)
            }
            let checksum = try await withTaskCancellationHandler {
                try await checksumTask.value
            } onCancel: {
                checksumTask.cancel()
            }
            try Task.checkCancellation()
            guard checksum == artifact.expectedSHA256 else {
                throw CocoaError(.fileReadCorruptFile)
            }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: partialURL)
            logger.notice("\(model.displayName, privacy: .public) verification cancelled")
            return
        } catch {
            try? FileManager.default.removeItem(at: partialURL)
            reportFailure(error, for: model)
            return
        }

        do {
            try Task.checkCancellation()
            // Commit the checksum first so the final model move makes the installation visible atomically.
            try artifact.expectedSHA256.write(
                to: artifact.checksumFileURL,
                atomically: true,
                encoding: .utf8
            )
            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: artifact.modelFileURL)
            try FileManager.default.moveItem(at: partialURL, to: artifact.modelFileURL)
            guard artifact.installedModelFileURL != nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            logger.notice("\(model.displayName, privacy: .public) installed successfully")
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: partialURL)
            try? FileManager.default.removeItem(at: artifact.checksumFileURL)
            logger.notice("\(model.displayName, privacy: .public) installation cancelled")
        } catch {
            if !artifact.modelFileIsValid(in: artifact.modelDirectory) {
                try? FileManager.default.removeItem(at: artifact.modelFileURL)
                try? FileManager.default.removeItem(at: artifact.checksumFileURL)
            }
            reportFailure(error, for: model)
        }
    }

    private func downloadArtifact(
        _ artifact: TranscribeCppModelArtifact,
        to partialURL: URL,
        modelName: String,
        downloadID: UUID
    ) async throws {
        let logger = logger
        try await ResumableFileDownloader().download(
            from: artifact.downloadURL,
            to: partialURL,
            expectedByteCount: artifact.expectedFileSize,
            progress: { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.updateDownloadProgress(fraction, for: modelName, downloadID: downloadID)
                }
            },
            onRetry: { attempt, error in
                logger.warning(
                    "Model download attempt \(attempt, privacy: .public) failed; resuming: \(error.localizedDescription, privacy: .public)"
                )
            }
        )
    }

    func deleteModel(_ model: TranscribeCppModel) {
        guard let artifact = TranscribeCppModelCatalog.artifact(for: model.name) else { return }
        objectWillChange.send()
        artifact.removeInstalledFiles()
        NotificationCenter.default.post(
            name: .transcribeCppModelDeleted,
            object: nil,
            userInfo: ["modelName": model.name]
        )
        onModelDeleted?(model.name)
        onModelsChanged?()
    }

    func showModelInFinder(_ model: TranscribeCppModel) {
        guard
            let artifact = TranscribeCppModelCatalog.artifact(for: model.name),
            let modelFileURL = artifact.installedModelFileURL
        else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([modelFileURL])
    }

    private func updateDownloadProgress(_ fraction: Double, for modelName: String, downloadID: UUID) {
        guard activeDownloadIDs[modelName] == downloadID,
            fraction.isFinite,
            (0...1).contains(fraction)
        else {
            return
        }
        let currentFraction = downloadStatuses[modelName]?.fractionCompleted ?? 0
        guard fraction == 0 || fraction > currentFraction else { return }

        downloadStatuses[modelName] = TranscribeCppDownloadStatus(
            fractionCompleted: fraction,
            message: String(localized: "Downloading..."),
            isIndeterminate: false
        )
    }

    private func reportFailure(_ error: Error, for model: TranscribeCppModel) {
        logger.error("\(model.displayName, privacy: .public) download failed: \(error, privacy: .public)")
        NotificationManager.shared.showNotification(
            title: "\(model.displayName) download failed",
            type: .error
        )
    }
}
