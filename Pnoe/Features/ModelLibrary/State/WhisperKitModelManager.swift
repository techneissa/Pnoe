import AppKit
import Foundation
import WhisperKit
import os

@MainActor
final class WhisperKitModelManager: ObservableObject {
    static let shared = WhisperKitModelManager()
    private static let maximumDownloadAttempts = 3

    @Published private var downloadStatuses: [String: WhisperKitDownloadProgress] = [:]
    /// Models whose last download failed; cleared when the next attempt starts.
    @Published private var failedDownloads: Set<String> = []

    var onModelDeleted: ((String) -> Void)?
    var onModelsChanged: (() -> Void)?

    private let storage: WhisperKitStorage
    private var activeDownloadIDs: [String: UUID] = [:]
    private var activeDownloadTasks: [String: Task<Void, Never>] = [:]
    private let logger = Logger(subsystem: "com.techneissa.pnoe", category: "WhisperKitModelManager")

    init(storage: WhisperKitStorage = .default) {
        self.storage = storage
    }

    func isModelDownloaded(named modelName: String) -> Bool {
        WhisperKitCatalog.spec(named: modelName).map(storage.isInstalled) ?? false
    }

    func isModelDownloading(_ spec: WhisperKitModelSpec) -> Bool {
        activeDownloadIDs[spec.name] != nil
    }

    func downloadStatus(for spec: WhisperKitModelSpec) -> WhisperKitDownloadProgress? {
        downloadStatuses[spec.name]
    }

    func hasDownloadFailed(_ spec: WhisperKitModelSpec) -> Bool {
        failedDownloads.contains(spec.name)
    }

    func startDownload(_ spec: WhisperKitModelSpec) {
        guard activeDownloadTasks[spec.name] == nil else { return }
        failedDownloads.remove(spec.name)
        activeDownloadTasks[spec.name] = Task { [weak self] in
            guard let self else { return }
            await self.downloadModel(spec)
            self.activeDownloadTasks[spec.name] = nil
        }
    }

    func cancelDownload(_ spec: WhisperKitModelSpec) {
        activeDownloadTasks[spec.name]?.cancel()
    }

    func deleteModel(_ spec: WhisperKitModelSpec) {
        objectWillChange.send()
        let installed = WhisperKitCatalog.models.filter { storage.isInstalled($0) }
        storage.deleteFiles(for: spec, installedSpecs: installed)
        NotificationCenter.default.post(
            name: .whisperKitModelDeleted,
            object: nil,
            userInfo: ["modelName": spec.name]
        )
        onModelDeleted?(spec.name)
        onModelsChanged?()
    }

    func showModelInFinder(_ spec: WhisperKitModelSpec) {
        guard storage.isInstalled(spec) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([storage.modelFolder(for: spec)])
    }

    // MARK: - Download

    private func downloadModel(_ spec: WhisperKitModelSpec) async {
        guard activeDownloadIDs[spec.name] == nil, !storage.isInstalled(spec) else { return }

        let downloadID = UUID()
        activeDownloadIDs[spec.name] = downloadID
        downloadStatuses[spec.name] = WhisperKitDownloadProgress(
            fraction: 0, message: String(localized: "Downloading..."), isIndeterminate: false)

        defer {
            if activeDownloadIDs[spec.name] == downloadID {
                activeDownloadIDs[spec.name] = nil
                downloadStatuses[spec.name] = nil
                onModelsChanged?()
            }
        }

        do {
            try await withRetries {
                try await self.fetchFiles(of: spec, downloadID: downloadID)
            }
            try Task.checkCancellation()

            downloadStatuses[spec.name] = WhisperKitDownloadProgress(
                fraction: 1, message: String(localized: "Verifying..."), isIndeterminate: true)
            // The downloader checks each large file against its published SHA-256; this checks that
            // every file of the model arrived.
            try storage.markInstalled(spec)
            logger.notice("\(spec.displayName, privacy: .public) installed successfully")
        } catch is CancellationError {
            // Partial files stay in the downloader's cache so the next attempt resumes.
            logger.notice("\(spec.displayName, privacy: .public) download cancelled")
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            if error is CocoaError {
                // Files that do not add up are not worth resuming.
                storage.deleteFiles(
                    for: spec,
                    installedSpecs: WhisperKitCatalog.models.filter { storage.isInstalled($0) })
            }
            reportFailure(error, for: spec)
        }
    }

    private func fetchFiles(of spec: WhisperKitModelSpec, downloadID: UUID) async throws {
        let hub = HubApiWrapper(downloadBase: storage.base)
        let modelShare = Double(spec.modelBytes) / Double(spec.totalBytes)

        _ = try await hub.snapshot(
            from: HubApiWrapper.Repo(id: WhisperKitCatalog.repository),
            revision: WhisperKitCatalog.revision,
            matching: ["\(spec.variant)/*"]
        ) { [weak self] progress in
            let fraction = progress.fractionCompleted * modelShare
            Task { @MainActor [weak self] in
                self?.updateDownloadProgress(fraction, for: spec.name, downloadID: downloadID)
            }
        }
        try Task.checkCancellation()

        _ = try await hub.snapshot(
            from: HubApiWrapper.Repo(id: spec.tokenizerRepository),
            revision: spec.tokenizerRevision,
            matching: WhisperKitCatalog.tokenizerFiles
        )
    }

    private func withRetries(_ operation: () async throws -> Void) async throws {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            do {
                try await operation()
                return
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                guard attempt < Self.maximumDownloadAttempts, error is URLError else { throw error }
                logger.warning(
                    "WhisperKit download attempt \(attempt, privacy: .public) failed; resuming: \(error.localizedDescription, privacy: .public)"
                )
                try await Task.sleep(for: .seconds(attempt))
                attempt += 1
            }
        }
    }

    private func updateDownloadProgress(_ fraction: Double, for modelName: String, downloadID: UUID) {
        guard activeDownloadIDs[modelName] == downloadID,
            fraction.isFinite,
            (0...1).contains(fraction)
        else {
            return
        }
        let current = downloadStatuses[modelName]?.fraction ?? 0
        guard fraction > current else { return }
        downloadStatuses[modelName] = WhisperKitDownloadProgress(
            fraction: fraction, message: String(localized: "Downloading..."), isIndeterminate: false)
    }

    private func reportFailure(_ error: Error, for spec: WhisperKitModelSpec) {
        logger.error("\(spec.displayName, privacy: .public) download failed: \(error, privacy: .public)")
        failedDownloads.insert(spec.name)
        NotificationManager.shared.showNotification(
            title: "\(spec.displayName) download failed",
            type: .error
        )
    }
}
