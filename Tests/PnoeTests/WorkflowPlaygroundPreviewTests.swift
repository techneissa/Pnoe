import AppKit
import SwiftUI
import XCTest

/// Renders the Workflows Playground offscreen with a sample pair, with a window-less `NSHostingView` and
/// `cacheDisplay(in:to:)` so native controls draw. Nothing is shown on screen and no model runs: the runner
/// is a stub. The folder comes from `PNOE_PLAYGROUND_PNG_DIR` (pass it to xcodebuild as
/// `TEST_RUNNER_PNOE_PLAYGROUND_PNG_DIR`) and defaults to a temporary folder.
@MainActor
final class WorkflowPlaygroundPreviewTests: XCTestCase {
    private var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["PNOE_PLAYGROUND_PNG_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnoe-playground-png")
    }

    private func render<V: View>(_ view: V, size: CGSize, name: String, dark: Bool = false) throws {
        _ = NSApplication.shared
        let host = NSHostingView(
            rootView: view
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        var distinctColors = Set<UInt32>()
        for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 7) {
                let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                let r = UInt32((c?.redComponent ?? 0) * 255)
                let g = UInt32((c?.greenComponent ?? 0) * 255)
                let b = UInt32((c?.blueComponent ?? 0) * 255)
                distinctColors.insert(r << 16 | g << 8 | b)
            }
        }
        XCTAssertGreaterThan(distinctColors.count, 8, "\(name) rendered blank")

        let directory = outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    /// A model that has already run a sample (stub runner) and holds two saved examples in a temporary file.
    private func sampleModel(fallbackReason: String?, rejected: String? = nil) async throws -> WorkflowPlaygroundModel {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pnoe-playground-render-\(UUID().uuidString)")
        let store = PlaygroundExampleStore(fileURL: folder.appendingPathComponent("examples.jsonl"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try store.append(
            .make(
                raw: "um so the demo is on thursday at three", output: "So the demo is on Thursday at 3.",
                expected: "So the demo is on Thursday at 3.", workflowName: "Cleaned Text", template: .cleanedText,
                id: "mine-demo-a", now: now))
        try store.append(
            .make(
                raw: "first call Sam second send the file third book the room",
                output: "First, call Sam. Second, send the file. Third, book the room.",
                expected: "First call Sam, second send the file, third book the room.", workflowName: "Cleaned Text",
                template: .cleanedText, id: "mine-demo-b", now: now))

        let cleaned = PlaygroundWorkflow(id: UUID(), name: "Cleaned Text", symbol: "text.badge.checkmark", template: .cleanedText)
        let summary = PlaygroundWorkflow(id: UUID(), name: "Summary", symbol: "text.alignleft", template: .summary)
        let model = WorkflowPlaygroundModel(workflows: [cleaned, summary], store: store) { text, _ in
            PlaygroundOutcome(
                output: fallbackReason == nil
                    ? "Open the file on Thursday and send it to Sam, please."
                    : "Open the file on Thursday and send it to Sam please.",
                duration: 1.8, fallbackReason: fallbackReason, rejectedText: rejected)
        }
        model.input = "um open the file on thursday and send it to Sam please"
        await model.run()
        return model
    }

    func testRenderPlaygroundAfterARun() async throws {
        let model = try await sampleModel(fallbackReason: nil)
        let view = WorkflowPlaygroundView(model: model, onDismiss: {})
        try render(view, size: CGSize(width: 720, height: 760), name: "playground")
        try render(view, size: CGSize(width: 720, height: 760), name: "playground-dark", dark: true)
    }

    func testRenderPlaygroundWhenTheChecksFellBack() async throws {
        let model = try await sampleModel(
            fallbackReason: "new_words", rejected: "Open the file on Thursday and email it to Sam, please, at your earliest.")
        XCTAssertNotNil(model.rejectedDiff)
        XCTAssertNotNil(model.fallbackSentence)
        let view = WorkflowPlaygroundView(model: model, onDismiss: {})
        try render(view, size: CGSize(width: 720, height: 900), name: "playground-fallback")
    }

    func testRenderEmptyPlayground() throws {
        let store = PlaygroundExampleStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("nothing-\(UUID().uuidString).jsonl"))
        let model = WorkflowPlaygroundModel(workflows: [], store: store) { _, _ in
            PlaygroundOutcome(output: "", duration: 0)
        }
        try render(WorkflowPlaygroundView(model: model, onDismiss: {}), size: CGSize(width: 720, height: 360), name: "playground-empty")
    }
}
