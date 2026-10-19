// swift-tools-version: 6.2
import PackageDescription

// MLX lives in its own package, like llama.cpp in `PnoeLlama`, so `swift test` on `PnoeFormatter` needs no MLX
// build. The app links `MLXRuntime` into the `PnoeFormatterMLXXPC` service only: the llama service and the app
// never carry MLX, and an MLX crash never reaches either. MLX needs `xcodebuild` for its Metal library (SwiftPM
// on the command line cannot build the shaders), so the eval CLI cannot host it.
let package = Package(
    name: "PnoeMLX",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MLXRuntime", targets: ["MLXRuntime"]),
    ],
    dependencies: [
        .package(path: "../PnoeFormatter"),
        // MIT. Pinned: every bump needs the eval run again.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        // Apache-2.0. mlx-swift-lm takes its tokenizer from here (`MLXLMCommon.Tokenizer` is adapted by hand
        // in `TokenizerBridge`, without the macros, so swift-syntax is not built).
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.5"),
        // Apache-2.0. The tests render chat templates with it, as swift-transformers does.
        .package(url: "https://github.com/huggingface/swift-jinja", from: "2.4.2"),
    ],
    targets: [
        .target(
            name: "MLXRuntime",
            dependencies: [
                .product(name: "FormatterCore", package: "PnoeFormatter"),
                .product(name: "FormatterMLXSupport", package: "PnoeFormatter"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            // MLX arrays and model contexts are not `Sendable`; the runtime keeps them inside one actor.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MLXRuntimeTests",
            dependencies: [
                "MLXRuntime",
                .product(name: "FormatterCore", package: "PnoeFormatter"),
                .product(name: "FormatterMLXSupport", package: "PnoeFormatter"),
                .product(name: "Jinja", package: "swift-jinja"),
            ]
        ),
    ]
)
