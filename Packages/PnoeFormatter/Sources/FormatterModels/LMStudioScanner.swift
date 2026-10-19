import Foundation

/// Models in LM Studio's folder: `<root>/<publisher>/<repo>/`. Read-only.
public struct LMStudioScanner: Sendable {
    public var modelsDirectory: URL

    public init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
    }

    public static func modelsDirectory(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".lmstudio", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    public func scan() -> [FormatterModelEntry] {
        let fileManager = FileManager.default
        func folders(in directory: URL) -> [URL] {
            ((try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? [])
            .filter { url in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        var result: [FormatterModelEntry] = []
        for publisher in folders(in: modelsDirectory) {
            for repo in folders(in: publisher) {
                let org = publisher.lastPathComponent
                let name = repo.lastPathComponent
                result += ModelFolderScanner().entries(
                    in: repo,
                    options: .init(org: org, repo: name, source: .lmStudio, idPrefix: "lmstudio:\(org)/\(name)")
                )
            }
        }
        return result
    }
}
