import Foundation

/// The installed models the formatter can use, from the general model stores only: Ollama, the Hugging Face
/// cache, LM Studio's folder and the files the user chose. Never another app's private folder. Discovery is
/// read-only and never moves, copies or deletes anything.
public struct FormatterModelCatalog: Sendable {
    public struct Configuration: Sendable {
        public var ollamaEndpoint: URL
        public var ollamaTimeout: TimeInterval
        public var environment: [String: String]
        public var homeDirectory: URL
        /// Overrides for the two folders; nil means the defaults under `homeDirectory`.
        public var huggingFaceHubDirectory: URL?
        public var lmStudioModelsDirectory: URL?
        public var ollamaStoreDirectory: URL?
        public var userChosenPaths: [URL]
        public var urlSessionConfiguration: URLSessionConfiguration

        public init(
            ollamaEndpoint: URL = OllamaModelDiscovery.defaultEndpoint,
            ollamaTimeout: TimeInterval = OllamaModelDiscovery.defaultTimeout,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
            huggingFaceHubDirectory: URL? = nil,
            lmStudioModelsDirectory: URL? = nil,
            ollamaStoreDirectory: URL? = nil,
            userChosenPaths: [URL] = [],
            urlSessionConfiguration: URLSessionConfiguration = .ephemeral
        ) {
            self.ollamaEndpoint = ollamaEndpoint
            self.ollamaTimeout = ollamaTimeout
            self.environment = environment
            self.homeDirectory = homeDirectory
            self.huggingFaceHubDirectory = huggingFaceHubDirectory
            self.lmStudioModelsDirectory = lmStudioModelsDirectory
            self.ollamaStoreDirectory = ollamaStoreDirectory
            self.userChosenPaths = userChosenPaths
            self.urlSessionConfiguration = urlSessionConfiguration
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Ollama models first, then Hugging Face, LM Studio, Ollama's model store and the user's own, each sorted by name. Entries with
    /// the same id (the same path chosen twice) appear once.
    public func installedModels() async -> [FormatterModelEntry] {
        let configuration = self.configuration
        async let ollama = OllamaModelDiscovery(
            endpoint: configuration.ollamaEndpoint,
            timeout: configuration.ollamaTimeout,
            configuration: configuration.urlSessionConfiguration
        ).fetch()
        async let files = Task.detached(priority: .utility) {
            Self.scanFiles(configuration)
        }.value

        let all = await ollama + files
        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted }
    }

    /// The models a llama.cpp runtime can load, from disk only: GGUF files in the Hugging Face cache, LM Studio's
    /// folder, Ollama's model store (Ollama need not run) and the files the user chose. Ollama's daemon is not
    /// asked, so this never waits on the network.
    public func installedGGUFModels() async -> [FormatterModelEntry] {
        let configuration = self.configuration
        return await Task.detached(priority: .utility) { Self.ggufModels(configuration) }.value
    }

    /// `installedGGUFModels()` on the calling thread, for a caller that must know now (it reads a few folders).
    public func installedGGUFModelsNow() -> [FormatterModelEntry] {
        Self.ggufModels(configuration)
    }

    /// The models a file-based runtime can load: the GGUF files `installedGGUFModels()` lists, and the MLX folders
    /// found in the same places (Hugging Face cache, LM Studio's folder, the folders the user chose). Disk only.
    public func installedFileModels() async -> [FormatterModelEntry] {
        let configuration = self.configuration
        return await Task.detached(priority: .utility) { Self.fileModels(configuration) }.value
    }

    /// `installedFileModels()` on the calling thread.
    public func installedFileModelsNow() -> [FormatterModelEntry] {
        Self.fileModels(configuration)
    }

    private static func fileModels(_ configuration: Configuration) -> [FormatterModelEntry] {
        var seen = Set<String>()
        return scanFiles(configuration).filter { ($0.kind == .gguf || $0.kind == .mlx) && seen.insert($0.id).inserted }
    }

    private static func ggufModels(_ configuration: Configuration) -> [FormatterModelEntry] {
        var seen = Set<String>()
        return scanFiles(configuration).filter { $0.kind == .gguf && seen.insert($0.id).inserted }
    }

    private static func scanFiles(_ configuration: Configuration) -> [FormatterModelEntry] {
        let hub = configuration.huggingFaceHubDirectory
            ?? HuggingFaceCacheScanner.hubDirectory(
                environment: configuration.environment,
                homeDirectory: configuration.homeDirectory
            )
        let lmStudio = configuration.lmStudioModelsDirectory
            ?? LMStudioScanner.modelsDirectory(homeDirectory: configuration.homeDirectory)
        let ollamaStore = configuration.ollamaStoreDirectory
            ?? OllamaStoreScanner.storeDirectory(
                environment: configuration.environment, homeDirectory: configuration.homeDirectory)

        func sorted(_ entries: [FormatterModelEntry]) -> [FormatterModelEntry] {
            entries.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        }
        return sorted(HuggingFaceCacheScanner(hubDirectory: hub).scan())
            + sorted(LMStudioScanner(modelsDirectory: lmStudio).scan())
            + OllamaStoreScanner(storeDirectory: ollamaStore).scan()
            + sorted(UserChosenModelScanner(paths: configuration.userChosenPaths).scan())
    }
}
