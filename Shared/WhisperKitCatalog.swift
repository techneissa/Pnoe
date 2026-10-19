import Foundation

/// One Core ML Whisper build from `argmaxinc/whisperkit-coreml` that WhisperKit can run.
struct WhisperKitModelSpec: Equatable, Sendable {
    /// Selection key stored in settings and modes.
    let name: String
    let displayName: String
    let description: String
    /// Folder inside the model repository.
    let variant: String
    /// Bytes of every file in `variant`, read from the Hugging Face API.
    let modelBytes: Int64
    /// The `openai/whisper-*` repository whose tokenizer this build uses.
    let tokenizerRepository: String
    let tokenizerRevision: String
    /// Bytes of `WhisperKitCatalog.tokenizerFiles` in the tokenizer repository.
    let tokenizerBytes: Int64
    let isMultilingual: Bool
    let speed: Double
    let accuracy: Double
    let ramUsage: Double

    /// What the download transfers, shown before the user starts it.
    var totalBytes: Int64 { modelBytes + tokenizerBytes }
    var formattedSize: String { WhisperKitCatalog.formattedSize(totalBytes) }
}

enum WhisperKitCatalog {
    static let repository = "argmaxinc/whisperkit-coreml"
    /// Commit of `repository` the sizes below were read from; downloads use it, not `main`.
    static let revision = "0f63a7800b00dd0226abd051b906c246e1907482"
    static let tokenizerFiles = ["config.json", "tokenizer_config.json", "tokenizer.json"]
    /// The Core ML packages WhisperKit loads. A folder without all of them is not a model.
    static let requiredComponents = ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"]

    static let largeV3Turbo = WhisperKitModelSpec(
        name: "whisperkit-large-v3-turbo",
        displayName: "Large v3 Turbo (WhisperKit)",
        description: "Large v3 Turbo on the Neural Engine, 4-bit weights. Accurate, multilingual and light on the GPU",
        variant: "openai_whisper-large-v3-v20240930_turbo_632MB",
        modelBytes: 645_668_913,
        tokenizerRepository: "openai/whisper-large-v3",
        tokenizerRevision: "06f233fe06e710322aca913c1bc4249a0d71fce1",
        tokenizerBytes: 2_764_732,
        isMultilingual: true,
        speed: 0.8,
        accuracy: 0.94,
        ramUsage: 1.0
    )

    static let small = WhisperKitModelSpec(
        name: "whisperkit-small",
        displayName: "Small (WhisperKit)",
        description: "Small model on the Neural Engine, a good balance of speed and accuracy across languages",
        variant: "openai_whisper-small_216MB",
        modelBytes: 217_350_763,
        tokenizerRepository: "openai/whisper-small",
        tokenizerRevision: "973afd24965f72e36ca33b3055d56a652f456b4d",
        tokenizerBytes: 2_765_116,
        isMultilingual: true,
        speed: 0.9,
        accuracy: 0.82,
        ramUsage: 0.5
    )

    static let base = WhisperKitModelSpec(
        name: "whisperkit-base",
        displayName: "Base (WhisperKit)",
        description: "Base model on the Neural Engine, fast with modest accuracy",
        variant: "openai_whisper-base",
        modelBytes: 146_719_453,
        tokenizerRepository: "openai/whisper-base",
        tokenizerRevision: "e37978b90ca9030d5170a5c07aadb050351a65bb",
        tokenizerBytes: 2_765_132,
        isMultilingual: true,
        speed: 0.95,
        accuracy: 0.72,
        ramUsage: 0.3
    )

    static let models: [WhisperKitModelSpec] = [largeV3Turbo, small, base]

    static func spec(named name: String) -> WhisperKitModelSpec? {
        models.first { $0.name == name }
    }

    /// "646 MB" or "1.5 GB", the way the other model cards write sizes.
    static func formattedSize(_ bytes: Int64) -> String {
        if bytes >= 1_000_000_000 {
            return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        }
        return String(format: "%d MB", Int((Double(bytes) / 1_000_000).rounded()))
    }
}

/// Where WhisperKit models live and which files belong to which model. The layout is the one the
/// Hugging Face downloader writes: `<base>/models/<repo>/…` with resume data under
/// `<base>/models/<repo>/.cache/huggingface/download/…`.
struct WhisperKitStorage: Sendable {
    let base: URL

    static var defaultBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.techneissa.Pnoe", isDirectory: true)
            .appendingPathComponent("WhisperKit", isDirectory: true)
    }

    static let `default` = WhisperKitStorage(base: defaultBase)

    func repositoryFolder(_ repository: String) -> URL {
        base.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repository, isDirectory: true)
    }

    func modelFolder(for spec: WhisperKitModelSpec) -> URL {
        repositoryFolder(WhisperKitCatalog.repository).appendingPathComponent(spec.variant, isDirectory: true)
    }

    /// Resume data and checksums the downloader keeps for this model's files only.
    func downloadCacheFolder(for spec: WhisperKitModelSpec) -> URL {
        repositoryFolder(WhisperKitCatalog.repository)
            .appendingPathComponent(".cache/huggingface/download", isDirectory: true)
            .appendingPathComponent(spec.variant, isDirectory: true)
    }

    func tokenizerFolder(for spec: WhisperKitModelSpec) -> URL {
        repositoryFolder(spec.tokenizerRepository)
    }

    private func completionMarker(for spec: WhisperKitModelSpec) -> URL {
        modelFolder(for: spec).appendingPathComponent(".pnoe-complete", isDirectory: false)
    }

    func isInstalled(_ spec: WhisperKitModelSpec) -> Bool {
        let fileManager = FileManager.default
        guard
            let marker = try? String(contentsOf: completionMarker(for: spec), encoding: .utf8),
            marker.trimmingCharacters(in: .whitespacesAndNewlines) == String(spec.modelBytes)
        else {
            return false
        }
        let folder = modelFolder(for: spec)
        let hasComponents = WhisperKitCatalog.requiredComponents.allSatisfy {
            fileManager.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        let tokenizer = tokenizerFolder(for: spec).appendingPathComponent("tokenizer.json")
        return hasComponents && fileManager.fileExists(atPath: tokenizer.path)
    }

    /// Bytes of the model's own files on disk, ignoring hidden bookkeeping files.
    func modelBytesOnDisk(_ spec: WhisperKitModelSpec) -> Int64 {
        let folder = modelFolder(for: spec)
        guard
            let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    /// Records a finished download. Fails when the files on disk do not add up to the catalog size.
    func markInstalled(_ spec: WhisperKitModelSpec) throws {
        guard modelBytesOnDisk(spec) == spec.modelBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try String(spec.modelBytes).write(to: completionMarker(for: spec), atomically: true, encoding: .utf8)
    }

    /// Removes this model's folder and its resume data. The tokenizer folder goes too unless another
    /// installed model in `installedSpecs` shares it.
    func deleteFiles(for spec: WhisperKitModelSpec, installedSpecs: [WhisperKitModelSpec]) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: modelFolder(for: spec))
        try? fileManager.removeItem(at: downloadCacheFolder(for: spec))
        let tokenizerIsShared = installedSpecs.contains {
            $0.name != spec.name && $0.tokenizerRepository == spec.tokenizerRepository
        }
        if !tokenizerIsShared {
            try? fileManager.removeItem(at: tokenizerFolder(for: spec))
        }
    }
}
