import FormatterCore
import Foundation

/// Models in the Hugging Face hub cache: `models--org--name/snapshots/<revision>/`. Read-only.
public struct HuggingFaceCacheScanner: Sendable {
    public var hubDirectory: URL

    public init(hubDirectory: URL) {
        self.hubDirectory = hubDirectory
    }

    /// Where the hub cache is: `HF_HUB_CACHE`, else `HF_HOME/hub`, else `XDG_CACHE_HOME/huggingface/hub`, else
    /// `~/.cache/huggingface/hub`, the order the Hugging Face tools use.
    public static func hubDirectory(environment: [String: String], homeDirectory: URL) -> URL {
        func path(_ key: String) -> String? {
            guard let value = environment[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
            return value
        }
        if let hub = path("HF_HUB_CACHE") {
            return URL(fileURLWithPath: hub, isDirectory: true)
        }
        if let home = path("HF_HOME") {
            return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("hub", isDirectory: true)
        }
        if let xdg = path("XDG_CACHE_HOME") {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent("huggingface", isDirectory: true)
                .appendingPathComponent("hub", isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("hub", isDirectory: true)
    }

    public func scan() -> [FormatterModelEntry] {
        let fileManager = FileManager.default
        let folders = (try? fileManager.contentsOfDirectory(
            at: hubDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var result: [FormatterModelEntry] = []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let (org, repo) = Self.repository(fromFolderName: folder.lastPathComponent),
                  let snapshot = currentSnapshot(of: folder)
            else { continue }
            let scanner = ModelFolderScanner()
            result += scanner.entries(
                in: snapshot,
                options: .init(org: org, repo: repo, source: .huggingFaceCache, idPrefix: "hf:\(org)/\(repo)")
            )
        }
        return result
    }

    /// `models--mlx-community--Qwen3-4B-4bit` is `mlx-community/Qwen3-4B-4bit`. Datasets and spaces are not models.
    static func repository(fromFolderName name: String) -> (org: String, repo: String)? {
        guard name.hasPrefix("models--") else { return nil }
        let rest = name.dropFirst("models--".count)
        guard let separator = rest.range(of: "--") else { return nil }
        let org = String(rest[..<separator.lowerBound])
        let repo = String(rest[separator.upperBound...])
        guard !org.isEmpty, !repo.isEmpty else { return nil }
        return (org, repo)
    }

    /// The revision `refs/main` points to; without it the most recently changed snapshot.
    private func currentSnapshot(of repositoryFolder: URL) -> URL? {
        let fileManager = FileManager.default
        let snapshots = repositoryFolder.appendingPathComponent("snapshots", isDirectory: true)

        if let ref = try? String(contentsOf: repositoryFolder.appendingPathComponent("refs/main"), encoding: .utf8) {
            let candidate = snapshots.appendingPathComponent(ref.trimmingCharacters(in: .whitespacesAndNewlines))
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
        }

        let revisions = (try? fileManager.contentsOfDirectory(
            at: snapshots,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return revisions.max { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
    }
}
