import Foundation

/// The one model Pnoe can download for the formatter, for a Mac with no model installed. Same layout as
/// `TranscribeCppModelArtifact`: a `.partial` file while downloading, the `.gguf`, and a `.sha256` marker whose
/// presence next to a file of the right size means the install is complete and checked.
struct FormatterModelArtifact: Sendable {
    let modelName: String
    let displayName: String
    let fileName: String
    let repository: String
    let repositoryRevision: String
    let expectedFileSize: Int64
    let expectedSHA256: String
    /// What the model card tags.
    let licenseName: String
    /// The folder that holds `modelName/`. The app support folder unless a test passes its own.
    let rootDirectory: URL

    /// Gemma 4 E2B instruct, Unsloth's Q4_K_M GGUF, pinned to one commit. Size and hash are the Hugging Face
    /// LFS values for that commit (the `lfs.size` and `lfs.oid` of the file in the revision API).
    static func gemma4E2B(rootDirectory: URL = Self.defaultRootDirectory) -> FormatterModelArtifact {
        FormatterModelArtifact(
            modelName: "gemma-4-E2B-it",
            displayName: "Gemma 4 E2B",
            fileName: "gemma-4-E2B-it-Q4_K_M.gguf",
            repository: "unsloth/gemma-4-E2B-it-GGUF",
            repositoryRevision: "0314792d7f1f7e229411f620751375812bb9faf2",
            expectedFileSize: 3_106_738_272,
            expectedSHA256: "740185b21d22ceb83a11c3aa62ad5842ef32c70f6096d756bbee85a1e4ec34b8",
            licenseName: "Apache-2.0",
            rootDirectory: rootDirectory
        )
    }

    /// Free space the download asks for before it starts, on top of what the partial file already holds.
    static let minimumFreeBytes: Int64 = 4_000_000_000

    static var defaultRootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.techneissa.Pnoe", isDirectory: true)
            .appendingPathComponent("Formatter", isDirectory: true)
    }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(repositoryRevision)/\(fileName)")!
    }

    var modelDirectory: URL {
        rootDirectory.appendingPathComponent(modelName, isDirectory: true)
    }

    var partialFileURL: URL {
        modelDirectory.appendingPathComponent("\(fileName).partial", isDirectory: false)
    }

    var modelFileURL: URL {
        modelDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    var checksumFileURL: URL {
        modelDirectory.appendingPathComponent(".\(fileName).sha256", isDirectory: false)
    }

    var installedModelFileURL: URL? {
        modelFileIsValid ? modelFileURL : nil
    }

    var modelFileIsValid: Bool {
        guard ResumableFileDownloader.fileSize(at: modelFileURL) == expectedFileSize else { return false }
        let installedChecksum = try? String(contentsOf: checksumFileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return installedChecksum == expectedSHA256
    }

    func removeInstalledFiles() {
        try? FileManager.default.removeItem(at: modelDirectory)
    }

    /// "3.1 GB", shown next to the Download button before anything is fetched.
    var downloadSizeText: String {
        ByteCountFormatter.string(fromByteCount: expectedFileSize, countStyle: .file)
    }
}
