import Foundation

enum DictionarySyncError: Error, Equatable {
    /// The folder of the chosen sync file is gone (iCloud Drive turned off, the folder moved or deleted).
    /// Pnoe never creates it.
    case folderMissing
    /// The sync file is in iCloud but not on this Mac yet; a download was asked for.
    case notDownloaded
    /// The file exists but can't be read or is not a dictionary this version understands. It is left alone.
    case unreadableFile
    case writeFailed
    case storeFailed
    /// The file system refused the coordinated access for another reason.
    case failed
    case cancelled
    /// Entries to remove changed between the review and the pass; the review starts again.
    case changedDuringReview
}

/// What is in the sync location: the file, and every other copy of it that iCloud made when two Macs
/// wrote at once (versions of the file, or files such as `Dictionary Sync 2.json` next to it).
struct DictionarySyncDriveContents: Sendable {
    var main: Data?
    var conflicts: [Data] = []
}

struct DictionarySyncExchangeResult: Sendable {
    /// Replaces the file atomically; `nil` leaves it alone.
    var output: Data?
    /// Which conflict copies were merged. Those are marked resolved and removed after the write; the
    /// others (ones that can't be parsed) are left where they are.
    var consumedConflicts: Set<Int> = []
}

/// The chosen sync file. One call reads, merges and writes under one file coordination, so two Macs can't
/// overwrite each other's change between the read and the write.
protocol DictionarySyncDrive: Sendable {
    /// Reads the file and its conflict copies. Changes nothing.
    func read() throws -> DictionarySyncDriveContents

    /// Calls `body` with the contents. Whatever it throws is rethrown and nothing is written.
    func exchange(_ body: (DictionarySyncDriveContents) throws -> DictionarySyncExchangeResult) throws
}

/// A version of the file that iCloud kept apart because two Macs changed it at once.
protocol SyncConflictVersion {
    func contents() throws -> Data
    func markResolvedAndRemove() throws
}

protocol SyncConflictVersionProvider: Sendable {
    func unresolvedVersions(of url: URL) -> [any SyncConflictVersion]
}

struct FileVersionConflicts: SyncConflictVersionProvider {
    private struct Version: SyncConflictVersion {
        let version: NSFileVersion

        func contents() throws -> Data { try Data(contentsOf: version.url) }

        func markResolvedAndRemove() throws {
            version.isResolved = true
            try version.remove()
        }
    }

    func unresolvedVersions(of url: URL) -> [any SyncConflictVersion] {
        (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).map(Version.init)
    }
}

/// The sync file the user chose, in iCloud Drive or anywhere else. The app is not sandboxed, so this is a
/// plain path; when the folder is in iCloud Drive, iCloud moves the file between the Macs. The drive never
/// creates folders: a folder that is gone is an error the user sees.
final class SyncFileDrive: DictionarySyncDrive, @unchecked Sendable {
    let fileURL: URL
    private let conflictVersions: any SyncConflictVersionProvider

    init(fileURL: URL, conflictVersions: any SyncConflictVersionProvider = FileVersionConflicts()) {
        self.fileURL = fileURL
        self.conflictVersions = conflictVersions
    }

    private var folderURL: URL { fileURL.deletingLastPathComponent() }

    /// The stub macOS leaves while a file is only in iCloud (`.Name.json.icloud`).
    private var placeholderURL: URL {
        folderURL.appendingPathComponent(".\(fileURL.lastPathComponent).icloud")
    }

    // MARK: Reading

    func read() throws -> DictionarySyncDriveContents {
        try requireFolder()
        try requireDownloaded()
        var coordinationError: NSError?
        var failure: Error?
        var result = DictionarySyncDriveContents()
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: fileURL, options: [], error: &coordinationError
        ) { url in
            do {
                result = try self.gather(at: url).contents
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
        if coordinationError != nil { throw DictionarySyncError.failed }
        return result
    }

    func exchange(_ body: (DictionarySyncDriveContents) throws -> DictionarySyncExchangeResult) throws {
        try requireFolder()
        try requireDownloaded()
        var coordinationError: NSError?
        var failure: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: fileURL, options: .forMerging, error: &coordinationError
        ) { url in
            do {
                let gathered = try self.gather(at: url)
                let result = try body(gathered.contents)
                if let output = result.output {
                    do {
                        try output.write(to: url, options: .atomic)
                    } catch {
                        throw DictionarySyncError.writeFailed
                    }
                }
                // Merged copies go only after the merged file is safe.
                for index in result.consumedConflicts.sorted() where index < gathered.resolvers.count {
                    try? gathered.resolvers[index]()
                }
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
        if coordinationError != nil { throw DictionarySyncError.failed }
    }

    // MARK: Pieces

    private struct Gathered {
        var contents: DictionarySyncDriveContents
        var resolvers: [() throws -> Void]
    }

    /// The file and its conflict copies. A copy that can't be read is skipped (and so left where it is).
    private func gather(at url: URL) throws -> Gathered {
        let fileManager = FileManager.default
        var gathered = Gathered(contents: DictionarySyncDriveContents(), resolvers: [])
        if fileManager.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else { throw DictionarySyncError.unreadableFile }
            gathered.contents.main = data
        }
        for version in conflictVersions.unresolvedVersions(of: url) {
            guard let data = try? version.contents() else { continue }
            gathered.contents.conflicts.append(data)
            gathered.resolvers.append {
                try version.markResolvedAndRemove()
                try? NSFileVersion.removeOtherVersionsOfItem(at: url)
            }
        }
        for sibling in siblingCopies() {
            guard let data = try? Data(contentsOf: sibling) else { continue }
            gathered.contents.conflicts.append(data)
            gathered.resolvers.append { try FileManager.default.removeItem(at: sibling) }
        }
        return gathered
    }

    /// `Dictionary Sync 2.json` next to `Dictionary Sync.json`: what iCloud Drive names a second copy.
    private func siblingCopies() -> [URL] {
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let pathExtension = fileURL.pathExtension
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)) ?? []
        return names.sorted().compactMap { name in
            let copy = URL(fileURLWithPath: name)
            guard copy.pathExtension == pathExtension else { return nil }
            let base = copy.deletingPathExtension().lastPathComponent
            guard base.hasPrefix(stem + " "), Int(base.dropFirst(stem.count + 1)) != nil else { return nil }
            return folderURL.appendingPathComponent(name)
        }
    }

    private func requireFolder() throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { throw DictionarySyncError.folderMissing }
    }

    /// A file that is still only in iCloud is asked for and reported as not there yet; reading it now
    /// could block until it arrives, or read nothing.
    private func requireDownloaded() throws {
        let fileManager = FileManager.default
        let hasPlaceholder = fileManager.fileExists(atPath: placeholderURL.path)
        var notLocal = hasPlaceholder && !fileManager.fileExists(atPath: fileURL.path)
        if !notLocal, fileManager.fileExists(atPath: fileURL.path) {
            let values = try? fileURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            notLocal = values?.ubiquitousItemDownloadingStatus == .notDownloaded
        }
        guard notLocal else { return }
        try? fileManager.startDownloadingUbiquitousItem(at: fileURL)
        throw DictionarySyncError.notDownloaded
    }
}
