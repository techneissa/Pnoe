import Foundation

/// A fresh folder under the system temp directory, removed on `deinit`. Tests build fake model stores in it.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FormatterModelsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func file(_ path: String, bytes: Int = 8, contents: String? = nil) throws -> URL {
        let target = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = contents.map { Data($0.utf8) } ?? Data(repeating: 0x47, count: bytes)
        try data.write(to: target)
        return target
    }

    func symlink(_ path: String, to destination: URL) throws {
        let target = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: destination)
    }

    func directory(_ path: String) throws -> URL {
        let target = url.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }
}
