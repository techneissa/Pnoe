import Foundation

/// A file or folder the maintainer picked with "Choose file or folder…". The path is trusted: a `.gguf` file
/// is a GGUF model whatever its name, a folder with `config.json` and safetensors is an MLX model, and any other
/// folder is searched for GGUF files.
public struct UserChosenModelScanner: Sendable {
    public var paths: [URL]

    public init(paths: [URL]) {
        self.paths = paths
    }

    public func scan() -> [FormatterModelEntry] {
        var result: [FormatterModelEntry] = []
        for path in paths {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else { continue }
            let name = path.lastPathComponent
            let idPrefix = "file:" + path.standardizedFileURL.path

            if !isDirectory.boolValue {
                guard path.pathExtension.lowercased() == "gguf", let size = ModelFolderScanner.size(of: path) else { continue }
                result.append(
                    FormatterModelEntry(
                        id: idPrefix,
                        displayName: path.deletingPathExtension().lastPathComponent,
                        kind: .gguf,
                        sizeBytes: size,
                        source: .userChosen,
                        quantization: ModelNameRules.ggufQuantization(fileName: name),
                        spec: .init(modelURL: path)
                    )
                )
                continue
            }

            result += ModelFolderScanner().entries(
                in: path,
                options: .init(org: nil, repo: name, source: .userChosen, idPrefix: idPrefix, trusted: true)
            )
        }
        return result
    }
}
