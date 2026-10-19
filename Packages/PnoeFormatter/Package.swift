// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PnoeFormatter",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FormatterCore", targets: ["FormatterCore"]),
        .library(name: "FormatterOllama", targets: ["FormatterOllama"]),
        .library(name: "FormatterEvalKit", targets: ["FormatterEvalKit"]),
        .executable(name: "pnoe-format-eval", targets: ["pnoe-format-eval"]),
    ],
    targets: [
        .target(
            name: "FormatterCore",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "FormatterCoreTests",
            dependencies: ["FormatterCore"]
        ),
        // Ollama over HTTP: Foundation only, shared by the app and the eval CLI.
        .target(name: "FormatterOllama", dependencies: ["FormatterCore"]),
        .testTarget(name: "FormatterOllamaTests", dependencies: ["FormatterOllama", "FormatterCore"]),
        // Test set loader, scorers, replay and llama-server backends, reports.
        .target(name: "FormatterEvalKit", dependencies: ["FormatterCore", "FormatterOllama"]),
        .testTarget(name: "FormatterEvalTests", dependencies: ["FormatterEvalKit", "FormatterCore"]),
        .executableTarget(name: "pnoe-format-eval", dependencies: ["FormatterEvalKit"]),
    ]
)
