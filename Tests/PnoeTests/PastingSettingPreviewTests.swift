import AppKit
import SwiftUI
import XCTest

/// Renders the clipboard rows of Settings › Pasting offscreen, once per choice, light and dark. Nothing is shown on
/// screen. The folder comes from `PNOE_PASTING_PNG_DIR` (pass it to xcodebuild as
/// `TEST_RUNNER_PNOE_PASTING_PNG_DIR`) and defaults to a temporary folder.
@MainActor
final class PastingSettingPreviewTests: XCTestCase {
    private struct Harness: View {
        let restoreClipboard: Bool
        let dark: Bool
        @State private var delay = ClipboardPasteSettings.defaultRestoreDelay
        @State private var addToHistory = true
        @State private var restore: Bool

        init(restoreClipboard: Bool, dark: Bool) {
            self.restoreClipboard = restoreClipboard
            self.dark = dark
            _restore = State(initialValue: restoreClipboard)
        }

        var body: some View {
            Form {
                Section("Pasting") {
                    PastingSettingRows(restoreClipboard: $restore, restoreDelay: $delay, addToHistory: $addToHistory)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(width: 620, height: 230)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        }
    }

    private var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["PNOE_PASTING_PNG_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnoe-pasting-png")
    }

    private func render(restoreClipboard: Bool, dark: Bool, name: String) throws {
        let size = NSSize(width: 620, height: 230)
        let hostingView = NSHostingView(rootView: Harness(restoreClipboard: restoreClipboard, dark: dark))
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try png.write(to: outputDirectory.appendingPathComponent(name))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width))
    }

    func testRenderEachChoiceLightAndDark() throws {
        try render(restoreClipboard: false, dark: false, name: "pasting-keep-light.png")
        try render(restoreClipboard: false, dark: true, name: "pasting-keep-dark.png")
        try render(restoreClipboard: true, dark: false, name: "pasting-put-back-light.png")
        try render(restoreClipboard: true, dark: true, name: "pasting-put-back-dark.png")
    }
}
