// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PnoeFormatter",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FormatterCore", targets: ["FormatterCore"]),
        .library(name: "FormatterModels", targets: ["FormatterModels"]),
        .executable(name: "pnoe-list-models", targets: ["ListModels"]),
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
    ]
)
