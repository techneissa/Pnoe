import FormatterCore
import Foundation

/// Reads one model folder (a Hugging Face snapshot, an LM Studio repo folder, a folder the user chose) and
/// returns the GGUF and MLX models in it. Read-only: it lists directories and reads `config.json`.
struct ModelFolderScanner {
    /// How many folder levels below the root are searched for GGUF files. Hugging Face repos keep large
    /// quantizations in a subfolder (`BF16/model-00001-of-00002.gguf`).
    static let maximumGGUFDepth = 2

    var fileManager: FileManager = .default

    struct Options {
        var org: String?
        var repo: String
        var source: FormatterModelSource
        /// The start of every entry id from this folder, for example `hf:org/name`.
        var idPrefix: String
        /// A folder the user picked is trusted: no name rule for MLX, no auxiliary-file filter.
        var trusted = false
    }

    func entries(in root: URL, options: Options) -> [FormatterModelEntry] {
        if !options.trusted, ModelNameRules.isEmbeddingModel(name: options.repo) { return [] }
        var result = ggufEntries(in: root, options: options)
        if let mlx = mlxEntry(in: root, options: options) {
            result.append(mlx)
        }
        return result
    }

    // MARK: GGUF

    private func ggufEntries(in root: URL, options: Options) -> [FormatterModelEntry] {
        var result: [FormatterModelEntry] = []
        for file in files(in: root, depth: 0) where file.url.pathExtension.lowercased() == "gguf" {
            let name = file.url.lastPathComponent
            if !options.trusted, ModelNameRules.isAuxiliaryGGUF(fileName: name) { continue }
            var size: Int64? = Self.size(of: file.url)
            guard size != nil else { continue }

            if let shard = ModelNameRules.ggufShard(fileName: name) {
                // Offer a split model once, at its first shard, with the sizes of all shards added up.
                guard shard.index == 1 else { continue }
                size = shardTotal(firstShard: file.url, count: shard.count) ?? size
            }

            let stem = file.url.deletingPathExtension().lastPathComponent
            let id = options.idPrefix + "/" + file.relativePath
            result.append(
                FormatterModelEntry(
                    id: id,
                    displayName: ModelNameRules.ggufShard(fileName: name) == nil
                        ? stem : Self.stripShardSuffix(stem),
                    kind: .gguf,
                    sizeBytes: size,
                    source: options.source,
                    quantization: ModelNameRules.ggufQuantization(fileName: name),
                    spec: RuntimeModelSpec(modelURL: file.url)
                )
            )
        }
        return result.sorted { $0.id < $1.id }
    }

    private func shardTotal(firstShard: URL, count: Int) -> Int64? {
        let name = firstShard.lastPathComponent
        guard let range = name.range(of: #"-\d{5}-of-\d{5}\.gguf$"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let prefix = String(name[..<range.lowerBound])
        let suffix = String(format: "-of-%05d.gguf", count)
        var total: Int64 = 0
        for index in 1...count {
            let sibling = firstShard.deletingLastPathComponent()
                .appendingPathComponent(prefix + String(format: "-%05d", index) + suffix)
            guard let size = Self.size(of: sibling) else { return nil }
            total += size
        }
        return total
    }

    private static func stripShardSuffix(_ stem: String) -> String {
        stem.replacingOccurrences(of: #"-\d{5}-of-\d{5}$"#, with: "", options: .regularExpression)
    }

    // MARK: MLX

    private func mlxEntry(in root: URL, options: Options) -> FormatterModelEntry? {
        let configURL = root.appendingPathComponent("config.json")
        guard Self.size(of: configURL) != nil else { return nil }

        let safetensors = ((try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "safetensors" }
        let sizes = safetensors.compactMap(Self.size(of:))
        guard !sizes.isEmpty else { return nil }

        let config = Self.readConfig(at: configURL)
        let bits = (config?["quantization"] as? [String: Any])?["bits"] as? Int
        if !options.trusted {
            let named = ModelNameRules.looksLikeMLXName(org: options.org, name: options.repo)
            let isMLXCommunity = options.org?.lowercased() == "mlx-community"
            guard isMLXCommunity || (named && config?["quantization"] != nil) else { return nil }
        }

        var quantization = bits.map { "\($0)bit" }
        if quantization == nil, let range = options.repo.range(of: #"\d{1,2}bit"#, options: [.regularExpression, .caseInsensitive]) {
            quantization = options.repo[range].lowercased()
        }

        return FormatterModelEntry(
            id: options.idPrefix,
            displayName: options.repo,
            kind: .mlx,
            sizeBytes: sizes.reduce(0, +),
            source: options.source,
            quantization: quantization,
            spec: RuntimeModelSpec(modelURL: root)
        )
    }

    private static func readConfig(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: Files

    private struct FoundFile {
        var url: URL
        var relativePath: String
    }

    private func files(in directory: URL, depth: Int, prefix: String = "") -> [FoundFile] {
        let items = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        var found: [FoundFile] = []
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let relative = prefix + item.lastPathComponent
            var isDirectory: ObjCBool = false
            // `fileExists` follows symlinks, which is what the Hugging Face snapshot folder is made of.
            guard fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                if depth < Self.maximumGGUFDepth {
                    found += files(in: item, depth: depth + 1, prefix: relative + "/")
                }
            } else {
                found.append(FoundFile(url: item, relativePath: relative))
            }
        }
        return found
    }

    /// Size of a regular file, following symlinks. Nil for a missing file, a dangling link or a folder.
    static func size(of url: URL) -> Int64? {
        let resolved = url.resolvingSymlinksInPath()
        guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize
        else { return nil }
        return Int64(size)
    }
}
