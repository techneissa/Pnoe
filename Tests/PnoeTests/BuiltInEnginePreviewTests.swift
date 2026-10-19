import AppKit
import SwiftUI
import XCTest

/// Renders the AI Enhancement rows of the Workflow editor with Built-in chosen, offscreen, with a window-less
/// `NSHostingView` and `cacheDisplay(in:to:)` so native controls draw. Nothing is shown on screen and no model
/// is loaded; the rows are sample data. The folder comes from `PNOE_BUILTIN_PNG_DIR` (pass it to xcodebuild as
/// `TEST_RUNNER_PNOE_BUILTIN_PNG_DIR`) and defaults to a temporary folder.
@MainActor
final class BuiltInEnginePreviewTests: XCTestCase {
    private var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["PNOE_BUILTIN_PNG_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnoe-builtin-png")
    }

    private static let installed = [
        BuiltInModelRow(id: "a", title: "gemma-4-E2B-it-Q4_K_M", detail: "3.1 GB · Q4_K_M · Hugging Face"),
        BuiltInModelRow(id: "b", title: "gemma3:4b", detail: "3.3 GB · Q4_K_M · Ollama"),
        BuiltInModelRow(id: "c", title: "Qwen3-4B-Instruct-2507-Q8_0", detail: "4.3 GB · Q8_0 · LM Studio"),
        BuiltInModelRow(id: "d", title: "notes-cleanup-Q5_K_M", detail: "2.7 GB · Q5_K_M · Chosen file"),
    ]

    private struct Harness: View {
        let providers: [String]
        let rows: [BuiltInModelRow]
        @State var selection: String?
        let download: BuiltInDownloadRowState?
        var listsEveryChoice = false

        @ViewBuilder var body: some View {
            if listsEveryChoice {
                form.pickerStyle(.inline)
            } else {
                form
            }
        }

        private var form: some View {
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

    func testRenderInstalledModels() throws {
        let view = Harness(providers: providers, rows: Self.installed, selection: "a", download: nil)
        try render(view, size: NSSize(width: 560, height: 330), to: "builtin-models")
        try render(view, size: NSSize(width: 560, height: 330), to: "builtin-models-dark", dark: true)
        // The same rows with every choice listed: the providers and the four sample models.
        let open = Harness(providers: providers, rows: Self.installed, selection: "a", download: nil, listsEveryChoice: true)
        try render(open, size: NSSize(width: 560, height: 600), to: "builtin-choices")
    }

    func testRenderNothingInstalledWithTheDownloadRow() throws {
        let view = Harness(providers: providers, rows: [], selection: nil, download: gemma(.notInstalled))
        try render(view, size: NSSize(width: 560, height: 370), to: "builtin-download-offer")
    }

    func testRenderDownloadStates() throws {
        for (name, state) in [
            ("builtin-downloading", FormatterModelDownloadState.downloading(fraction: 0.42)),
            ("builtin-paused", .paused),
            ("builtin-failed", .failed("Not enough free disk space. The download needs 4 GB free.")),
        ] {
            let view = Harness(providers: providers, rows: Self.installed.prefix(1).map { $0 }, selection: "a", download: gemma(state))
            try render(view, size: NSSize(width: 560, height: 400), to: name)
        }
    }
}
