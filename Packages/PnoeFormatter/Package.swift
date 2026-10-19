// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PnoeFormatter",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FormatterCore", targets: ["FormatterCore"]),
        .library(name: "FormatterModels", targets: ["FormatterModels"]),
        .executable(name: "pnoe-list-models", targets: ["ListModels"]),
        .library(name: "FormatterOllama", targets: ["FormatterOllama"]),
        .library(name: "FormatterXPC", targets: ["FormatterXPC"]),
        .library(name: "FormatterMLXSupport", targets: ["FormatterMLXSupport"]),
        .library(name: "FormatterEvalKit", targets: ["FormatterEvalKit"]),
        .executable(name: "pnoe-format-eval", targets: ["pnoe-format-eval"]),
    ],
    targets: [
        .target(
            name: "FormatterCore",
            resources: [.process("Resources")]
        ),
        .target(
            name: "FormatterModels",
            dependencies: ["FormatterCore"]
        ),
        .executableTarget(
            name: "ListModels",
            dependencies: ["FormatterModels"]
        ),
        .testTarget(
            name: "FormatterCoreTests",
            dependencies: ["FormatterCore"]
        ),
        .testTarget(
            name: "FormatterModelsTests",
            dependencies: ["FormatterModels"]
        ),
        // Ollama over HTTP: Foundation only, shared by the app and the eval CLI.
        .target(name: "FormatterOllama", dependencies: ["FormatterCore"]),
        .testTarget(name: "FormatterOllamaTests", dependencies: ["FormatterOllama", "FormatterCore"]),
        // The model runs in an XPC service; this is the protocol, the service side and the client the app uses.
        .target(name: "FormatterXPC", dependencies: ["FormatterCore"]),
        .testTarget(name: "FormatterXPCTests", dependencies: ["FormatterXPC", "FormatterCore"]),
        // The MLX engine's text rules (chat template lookup, think block, prefix split), free of MLX itself so
        // this package's tests need no MLX build. `MLXRuntime` in Packages/PnoeMLX applies them.
        .target(name: "FormatterMLXSupport"),
        .testTarget(name: "FormatterMLXSupportTests", dependencies: ["FormatterMLXSupport"]),
        // Test set loader, scorers, replay and llama-server backends, reports.
        .target(name: "FormatterEvalKit", dependencies: ["FormatterCore", "FormatterOllama"]),
        .testTarget(name: "FormatterEvalTests", dependencies: ["FormatterEvalKit", "FormatterCore"]),
        .executableTarget(name: "pnoe-format-eval", dependencies: ["FormatterEvalKit"]),
    ]
)
