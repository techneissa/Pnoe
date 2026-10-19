// swift-tools-version: 6.0
import PackageDescription

// llama.cpp lives in its own package so `swift test` on PnoeFormatter needs no download. The app links
// `LlamaRuntime` into the XPC service only; the app itself already carries two ggml copies (whisper.xcframework
// and Transcribe-cpp-swift), and a third one there would risk duplicate classes and symbols.
let package = Package(
    name: "PnoeLlama",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LlamaRuntime", targets: ["LlamaRuntime"]),
    ],
    dependencies: [
        .package(path: "../PnoeFormatter"),
    ],
    targets: [
        // The official release asset of ggml-org/llama.cpp (MIT), pinned by build and checksum. Every bump
        // needs the eval run again.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11734/llama-b11734-xcframework.zip",
            checksum: "89457e336c7ad85048d03b1a2f6500cdadad0bdfef9a1aaedb9e0a4f19ea4b86"
        ),
        .target(
            name: "LlamaRuntime",
            dependencies: [
                "llama",
                .product(name: "FormatterCore", package: "PnoeFormatter"),
            ]
        ),
        .testTarget(name: "LlamaRuntimeTests", dependencies: ["LlamaRuntime"]),
    ]
)
