import AppKit
import SwiftUI
import XCTest

/// Renders the AI Enhancement rows of the Workflow editor with Built-in chosen, offscreen, with a window-less
/// `NSHostingView` and `cacheDisplay(in:to:)` so native controls draw. Nothing is shown on screen and no model
/// is loaded; the rows are sample data. The folder comes from `PNOE_BUILTIN_PNG_DIR` (pass it to xcodebuild as
/// `TEST_RUNNER_PNOE_BUILTIN_PNG_DIR`) and defaults to a temporary folder.
@MainActor
final class BuiltInEnginePreviewTests: XCTestCase {
    /// An offscreen test is not the app, so the source logos are looked up in the built app next to the test bundle.
    override func setUp() {
        super.setUp()
        let app = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Pnoe Dev.app")
        if let bundle = Bundle(url: app) { BuiltInSourceIcon.logoBundle = bundle }
    }

    private var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["PNOE_BUILTIN_PNG_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnoe-builtin-png")
    }

    private static let installed = [
        BuiltInModelRow(id: "a", name: "gemma-4-E2B-it", quantization: "Q4_K_M", sizeText: "3.1 GB", source: .huggingFaceCache),
        BuiltInModelRow(id: "b", name: "gemma3:4b-it", quantization: "Q4_K_M", sizeText: "3.3 GB", source: .ollamaStore),
        BuiltInModelRow(id: "c", name: "Qwen3-4B-Instruct-2507", quantization: "Q8_0", sizeText: "4.3 GB", source: .lmStudio),
        BuiltInModelRow(id: "d", name: "notes-cleanup", quantization: "Q5_K_M", sizeText: "2.7 GB", source: .userChosen),
        BuiltInModelRow(id: "e", name: "Gemma 4 E2B", quantization: "Q4_K_M", sizeText: "3.1 GB", source: .downloaded),
        BuiltInModelRow(id: "f", name: "Llama-3.2-1B-Instruct", quantization: "Q2_K", sizeText: "0.6 GB", source: .huggingFaceCache),
    ]

    /// GGUF and MLX models side by side, as the picker lists them when both kinds are on the Mac.
    private static let mixed = [
        BuiltInModelRow(id: "a", name: "gemma-4-E2B-it", quantization: "Q4_K_M", sizeText: "3.1 GB", source: .huggingFaceCache),
        BuiltInModelRow(
            id: "m1", name: "gemma-4-e2b-it", quantization: "4bit", sizeText: "2.4 GB", source: .huggingFaceCache, kind: .mlx),
        BuiltInModelRow(id: "c", name: "Qwen3-4B-Instruct-2507", quantization: "Q8_0", sizeText: "4.3 GB", source: .lmStudio),
        BuiltInModelRow(
            id: "m2", name: "Qwen3-4B-Instruct-2507", quantization: "8bit", sizeText: "4.3 GB", source: .lmStudio, kind: .mlx),
        BuiltInModelRow(
            id: "m3", name: "Llama-3.2-3B-Instruct", quantization: "4bit", sizeText: "1.8 GB", source: .userChosen, kind: .mlx),
        BuiltInModelRow(id: "o", name: "gemma3:4b-it", quantization: "Q4_K_M", sizeText: "3.3 GB", source: .ollamaStore),
    ]

    private struct Harness: View {
        let providers: [String]
        let rows: [BuiltInModelRow]
        @State var selection: String?
        let download: BuiltInDownloadRowState?

        var body: some View {
            Form {
                Section {
                    Toggle("AI Enhancement", isOn: .constant(true))
                    Picker("AI Provider", selection: .constant("Built-in")) {
                        ForEach(providers, id: \.self) { Text($0).tag($0) }
                    }
                    BuiltInEngineSectionContent(
                        rows: rows, selection: $selection, isLoading: false, download: download,
                        onChooseFile: {}, onDownload: {}, onCancelDownload: {}, onRemoveDownload: {})
                    Picker("Prompt", selection: .constant("Cleaned Text")) {
                        Text("Cleaned Text").tag("Cleaned Text")
                    }
                } header: {
                    Text("AI Enhancement")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(width: 560)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    /// What the popover looks like: its content on the material a popover is drawn on.
    private struct PopoverCard: View {
        let query: String
        var rows = BuiltInEnginePreviewTests.installed
        var selectedID = "a"
        var body: some View {
            BuiltInModelPopoverContent(rows: rows, selectedID: selectedID, initialQuery: query, startsShown: true, onSelect: { _ in }, onClose: {})
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.15)))
                .padding(20)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func render<V: View>(_ view: V, size: NSSize, to name: String, dark: Bool = false) throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        var distinct = Set<UInt32>()
        for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 7) {
                let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                distinct.insert(
                    UInt32((c?.redComponent ?? 0) * 255) << 16 | UInt32((c?.greenComponent ?? 0) * 255) << 8
                        | UInt32((c?.blueComponent ?? 0) * 255))
            }
        }
        XCTAssertGreaterThan(distinct.count, 8, "\(name) rendered blank")

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }

    private let providers = ["Gemini", "Ollama", "Built-in"]
    private func gemma(_ state: FormatterModelDownloadState) -> BuiltInDownloadRowState {
        BuiltInDownloadRowState(name: "Gemma 4 E2B", sizeText: "3.1 GB", licenseName: "Apache-2.0", state: state)
    }

    func testRenderThePickerClosed() throws {
        let view = Harness(providers: providers, rows: Self.installed, selection: "a", download: nil)
        try render(view, size: NSSize(width: 560, height: 360), to: "builtin-picker")
        try render(view, size: NSSize(width: 560, height: 360), to: "builtin-picker-dark", dark: true)
    }

    func testRenderThePopoverOpenWithASearchTerm() throws {
        try render(PopoverCard(query: "q4"), size: NSSize(width: 440, height: 270), to: "builtin-popover-search")
        try render(PopoverCard(query: "q4"), size: NSSize(width: 440, height: 270), to: "builtin-popover-search-dark", dark: true)
        try render(PopoverCard(query: ""), size: NSSize(width: 440, height: 400), to: "builtin-popover-all")
        try render(PopoverCard(query: "zzz"), size: NSSize(width: 440, height: 130), to: "builtin-popover-empty")
    }

    func testRenderMLXModelsInThePickerAndThePopover() throws {
        // An MLX model chosen: the closed picker shows its "MLX" badge next to the quantization.
        let closed = Harness(providers: providers, rows: Self.mixed, selection: "m1", download: nil)
        try render(closed, size: NSSize(width: 560, height: 360), to: "mlx-picker")
        try render(closed, size: NSSize(width: 560, height: 360), to: "mlx-picker-dark", dark: true)
        // The open popover lists GGUF and MLX models together, each with its source icon.
        let popover = PopoverCard(query: "", rows: Self.mixed, selectedID: "m1")
        try render(popover, size: NSSize(width: 440, height: 420), to: "mlx-popover")
        try render(popover, size: NSSize(width: 440, height: 420), to: "mlx-popover-dark", dark: true)
        // Searching "mlx" keeps the MLX models only.
        let search = PopoverCard(query: "mlx", rows: Self.mixed, selectedID: "m1")
        try render(search, size: NSSize(width: 440, height: 250), to: "mlx-popover-search")
        try render(search, size: NSSize(width: 440, height: 250), to: "mlx-popover-search-dark", dark: true)
    }

    func testRenderTheMissingModelAndTheEmptyList() throws {
        let missing = Harness(providers: providers, rows: Self.installed, selection: "unplugged-drive", download: nil)
        try render(missing, size: NSSize(width: 560, height: 360), to: "builtin-model-not-found")
        let empty = Harness(providers: providers, rows: [], selection: nil, download: gemma(.notInstalled))
        try render(empty, size: NSSize(width: 560, height: 380), to: "builtin-download-offer")
    }

    func testRenderDownloadStates() throws {
        for (name, state) in [
            ("builtin-downloading", FormatterModelDownloadState.downloading(fraction: 0.42)),
            ("builtin-paused", .paused),
            ("builtin-failed", .failed("Not enough free disk space. The download needs 4 GB free.")),
            ("builtin-finished", .ready),
        ] {
            let view = Harness(providers: providers, rows: Array(Self.installed.prefix(1)), selection: "a", download: gemma(state))
            try render(view, size: NSSize(width: 560, height: 420), to: name)
        }
    }
}
