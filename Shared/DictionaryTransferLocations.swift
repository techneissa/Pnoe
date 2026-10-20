import Foundation

/// A file or folder the user picked once, remembered across launches so the next click needs no dialog.
/// It stores a bookmark (which follows the item when it is moved or renamed) and the path (to name the
/// item when it is gone).
struct RememberedLocation {
    let defaults: UserDefaults
    let key: String

    func remember(_ url: URL) {
        defaults.set(url.path, forKey: key + ".path")
        if let bookmark = try? url.bookmarkData() {
            defaults.set(bookmark, forKey: key + ".bookmark")
        } else {
            defaults.removeObject(forKey: key + ".bookmark")
        }
    }

    /// The remembered URL. The item may no longer exist (check before using it); `nil` only when nothing
    /// was ever remembered.
    func resolve() -> URL? {
        if let bookmark = defaults.data(forKey: key + ".bookmark") {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
            {
                if isStale { remember(url) }
                return url
            }
        }
        return defaults.string(forKey: key + ".path").map { URL(fileURLWithPath: $0) }
    }

    func forget() {
        defaults.removeObject(forKey: key + ".path")
        defaults.removeObject(forKey: key + ".bookmark")
    }
}

enum DictionaryLocationKeys {
    static let syncFile = "dictionarySyncFile"
    static let exportFolder = "dictionaryExportFolder"
    static let importFile = "dictionaryImportFile"
}

/// Export to a remembered folder and import from a remembered file, without a dialog after the first
/// choice. Neither ever creates a folder.
enum DictionaryTransfer {
    /// `Pnoe Dictionary 2026-10-20 14.05.json` (local time). A name that is taken gets " 2", " 3"…, so an
    /// export never replaces an earlier one.
    static func exportFileName(at date: Date = Date(), calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "Pnoe Dictionary %04d-%02d-%02d %02d.%02d.json",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
    }

    enum Failure: LocalizedError, Equatable {
        case folderMissing(String)
        case fileMissing(String)

        var errorDescription: String? {
            switch self {
            case .folderMissing(let name):
                return String(format: String(localized: "The folder “%@” is gone. Choose another one."), name)
            case .fileMissing(let name):
                return String(format: String(localized: "The file “%@” is gone. Choose another one."), name)
            }
        }
    }

    /// Writes `data` into `folder` under a dated name; nothing is replaced.
    static func export(
        _ data: Data, toFolder folder: URL, at date: Date = Date(), calendar: Calendar = .current
    ) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw Failure.folderMissing(folder.lastPathComponent) }
        let name = exportFileName(at: date, calendar: calendar)
        let stem = (name as NSString).deletingPathExtension
        var url = folder.appendingPathComponent(name)
        var copy = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stem) \(copy).json")
            copy += 1
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    static func importData(from file: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw Failure.fileMissing(file.lastPathComponent)
        }
        return try Data(contentsOf: file)
    }
}

/// How the chosen sync file is shown ("Dictionary Sync.json · iCloud Drive/Pnoe") and where the file
/// panel starts.
struct DictionarySyncFileDescription: Equatable, Sendable {
    let name: String
    let folder: String

    static func iCloudDriveRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    static func describing(
        _ file: URL, iCloudRoot: URL = iCloudDriveRoot(), home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> DictionarySyncFileDescription {
        let folder = file.deletingLastPathComponent().standardizedFileURL.path
        let root = iCloudRoot.standardizedFileURL.path
        if folder == root {
            return DictionarySyncFileDescription(name: file.lastPathComponent, folder: "iCloud Drive")
        }
        if folder.hasPrefix(root + "/") {
            return DictionarySyncFileDescription(
                name: file.lastPathComponent, folder: "iCloud Drive/" + folder.dropFirst(root.count + 1))
        }
        let homePath = home.standardizedFileURL.path
        let shown = folder.hasPrefix(homePath + "/") ? "~" + folder.dropFirst(homePath.count) : folder
        return DictionarySyncFileDescription(name: file.lastPathComponent, folder: String(shown))
    }

    /// Where the panel opens: the `Pnoe` folder of the iCloud Drive if it exists, else the Drive itself,
    /// else nothing. Nothing is created.
    static func suggestedDirectory(iCloudRoot: URL = iCloudDriveRoot()) -> URL? {
        let fileManager = FileManager.default
        let pnoe = iCloudRoot.appendingPathComponent("Pnoe", isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: pnoe.path, isDirectory: &isDirectory), isDirectory.boolValue { return pnoe }
        if fileManager.fileExists(atPath: iCloudRoot.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return iCloudRoot
        }
        return nil
    }

    static let suggestedFileName = "Dictionary Sync.json"
}
