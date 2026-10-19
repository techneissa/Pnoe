import FormatterCore
import Foundation

/// Models in Ollama's own store, read from disk: `<store>/manifests/<host>/<namespace>/<model>/<tag>` names
/// a `application/vnd.ollama.image.model` layer whose file is `<store>/blobs/sha256-<digest>`. That blob is a
/// GGUF file for most models, so llama.cpp can load it with Ollama not running. Read-only: it lists folders,
/// reads manifests and the first four bytes of a blob, and never copies, moves or deletes anything.
public struct OllamaStoreScanner: Sendable {
    public var storeDirectory: URL

    public init(storeDirectory: URL) {
        self.storeDirectory = storeDirectory
    }

    /// Where Ollama keeps models: `OLLAMA_MODELS`, else `~/.ollama/models`.
    public static func storeDirectory(environment: [String: String], homeDirectory: URL) -> URL {
        if let custom = environment["OLLAMA_MODELS"]?.trimmingCharacters(in: .whitespaces), !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent(".ollama", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    static let modelLayerMediaType = "application/vnd.ollama.image.model"
    static let ggufMagic = Data("GGUF".utf8)

    private struct Manifest: Decodable {
        struct Layer: Decodable {
            var mediaType: String?
            var digest: String?
            var size: Int64?
        }
        var layers: [Layer]?
    }

    public func scan() -> [FormatterModelEntry] {
        let fileManager = FileManager.default
        let manifests = storeDirectory.appendingPathComponent("manifests", isDirectory: true)
        guard let walker = fileManager.enumerator(
            at: manifests, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }

        var result: [FormatterModelEntry] = []
        for case let file as URL in walker {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let name = Self.modelName(manifest: file, manifestsRoot: manifests),
                  let blob = modelBlob(manifest: file)
            else { continue }
            if ModelNameRules.isEmbeddingModel(name: name) { continue }
            let tag = file.lastPathComponent
            result.append(
                FormatterModelEntry(
                    id: "ollama-store:\(name)",
                    displayName: name,
                    kind: .gguf,
                    sizeBytes: blob.size,
                    source: .ollamaStore,
                    quantization: ModelNameRules.ggufQuantization(fileName: tag),
                    spec: RuntimeModelSpec(identifier: name, modelURL: blob.url)
                )
            )
        }
        return result.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// `registry.ollama.ai/library/gemma3/4b` is `gemma3:4b`; another namespace or host stays in the name.
    static func modelName(manifest: URL, manifestsRoot: URL) -> String? {
        let rootParts = manifestsRoot.standardizedFileURL.pathComponents
        let parts = manifest.standardizedFileURL.pathComponents
        guard parts.count > rootParts.count else { return nil }
        let relative = Array(parts[rootParts.count...])
        guard relative.count >= 3 else { return nil }
        let tag = relative[relative.count - 1]
        let model = relative[relative.count - 2]
        var prefix = Array(relative.dropLast(2))
        if prefix.first == "registry.ollama.ai" { prefix.removeFirst() }
        if prefix == ["library"] { prefix = [] }
        return (prefix + [model]).joined(separator: "/") + ":" + tag
    }

    private func modelBlob(manifest: URL) -> (url: URL, size: Int64)? {
        guard let data = try? Data(contentsOf: manifest),
              let decoded = try? JSONDecoder().decode(Manifest.self, from: data),
              let layer = decoded.layers?.first(where: { $0.mediaType == Self.modelLayerMediaType }),
              let digest = layer.digest, digest.hasPrefix("sha256:")
        else { return nil }
        let hex = digest.dropFirst("sha256:".count)
        // The digest names a file; anything with a separator in it is not one.
        guard !hex.isEmpty, !hex.contains("/"), !hex.contains("..") else { return nil }
        let blob = storeDirectory
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent("sha256-" + hex)
        guard let size = ModelFolderScanner.size(of: blob), Self.startsWithGGUFMagic(blob) else { return nil }
        return (blob, size)
    }

    private static func startsWithGGUFMagic(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == ggufMagic
    }
}
