import Foundation

enum DictionarySyncError: Error, Equatable {
    /// There is no iCloud Drive folder on this Mac (iCloud Drive is off or nobody is signed in).
    case driveUnavailable
    /// The sync file is in iCloud but not on this Mac yet; a download was asked for.
    case notDownloaded
    /// The file exists but can't be read or is not a dictionary this version understands. It is left alone.
    case unreadableFile
    case writeFailed
    case storeFailed
}

/// The place the sync file lives. One call reads, merges and writes under one file coordination, so two
/// Macs can't overwrite each other's change between the read and the write.
protocol DictionarySyncDrive: Sendable {
    /// Calls `body` with the file's content (`nil` when there is no file yet). A returned `Data` replaces
    /// the file atomically; `nil` leaves it alone. Whatever `body` throws is rethrown and nothing is written.
    func exchange(_ body: (Data?) throws -> Data?) throws

    /// Calls `onChange` after the file or its folder changed on disk, for a change made by someone else.
    func startWatching(_ onChange: @escaping @Sendable () -> Void)
    func stopWatching()
}

/// The sync file in a folder of the iCloud Drive: `~/Library/Mobile Documents/com~apple~CloudDocs/Pnoe/`.
/// The app is not sandboxed, so this is a plain path; iCloud Drive moves the file between the Macs.
final class FolderDrive: DictionarySyncDrive, @unchecked Sendable {
    static let folderName = "Pnoe"
    static let fileName = "Dictionary Sync.json"

    /// The user's iCloud Drive root, built from the real home folder.
    static func iCloudDriveRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    private let root: URL
    private let lock = NSLock()
    private var watcher: FolderWatcher?

    /// `root` is the drive's top folder; the sync file goes into `root/Pnoe/`. Tests pass a temporary folder.
    init(root: URL = FolderDrive.iCloudDriveRoot()) {
        self.root = root
    }

    var folderURL: URL { root.appendingPathComponent(Self.folderName, isDirectory: true) }
    var fileURL: URL { folderURL.appendingPathComponent(Self.fileName) }

    /// The stub macOS leaves while a file is only in iCloud (`.Name.json.icloud`).
    private var placeholderURL: URL {
        folderURL.appendingPathComponent(".\(Self.fileName).icloud")
    }

    func exchange(_ body: (Data?) throws -> Data?) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DictionarySyncError.driveUnavailable
        }
        do {
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            throw DictionarySyncError.writeFailed
        }
        try requireDownloaded()

        let coordinator = NSFileCoordinator(filePresenter: currentWatcher())
        var coordinationError: NSError?
        var failure: Error?
        coordinator.coordinate(writingItemAt: fileURL, options: .forMerging, error: &coordinationError) { url in
            let existing: Data?
            if fileManager.fileExists(atPath: url.path) {
                guard let data = try? Data(contentsOf: url) else {
                    failure = DictionarySyncError.unreadableFile
                    return
                }
                existing = data
            } else {
                existing = nil
            }
            do {
                guard let output = try body(existing) else { return }
                do {
                    try output.write(to: url, options: .atomic)
                } catch {
                    throw DictionarySyncError.writeFailed
                }
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
        if coordinationError != nil { throw DictionarySyncError.unreadableFile }
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

    // MARK: Watching

    private func currentWatcher() -> FolderWatcher? {
        lock.lock()
        defer { lock.unlock() }
        return watcher
    }

    func startWatching(_ onChange: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        watcher?.stop()
        let folder = folderURL
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let newWatcher = FolderWatcher(folder: folder, onChange: onChange)
        newWatcher.start()
        watcher = newWatcher
    }

    func stopWatching() {
        lock.lock()
        defer { lock.unlock() }
        watcher?.stop()
        watcher = nil
    }
}

/// Reports changes other processes make inside the folder (iCloud's daemon replacing the file, a
/// placeholder turning into the real file). A change this process makes through a coordinator that
/// names the watcher as its presenter is not reported back.
private final class FolderWatcher: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let onChange: @Sendable () -> Void

    init(folder: URL, onChange: @escaping @Sendable () -> Void) {
        presentedItemURL = folder
        presentedItemOperationQueue = OperationQueue()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
        presentedItemOperationQueue.qualityOfService = .utility
        self.onChange = onChange
    }

    func start() { NSFileCoordinator.addFilePresenter(self) }
    func stop() { NSFileCoordinator.removeFilePresenter(self) }

    func presentedItemDidChange() { onChange() }
    func presentedSubitemDidChange(at url: URL) { onChange() }
    func presentedSubitemDidAppear(at url: URL) { onChange() }
}
