// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PnoeFormatter",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FormatterCore", targets: ["FormatterCore"]),
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
    ]
)
