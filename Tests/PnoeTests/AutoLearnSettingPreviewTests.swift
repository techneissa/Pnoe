import AppKit
import SwiftUI
import XCTest

/// Renders the "Save a correction" setting row offscreen. Nothing is shown on screen. The folder comes from `PNOE_AUTOLEARN_PNG_DIR` (pass it to xcodebuild as
/// `TEST_RUNNER_PNOE_AUTOLEARN_PNG_DIR`) and defaults to a temporary folder.
@MainActor
final class AutoLearnSettingPreviewTests: XCTestCase {
    private var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["PNOE_AUTOLEARN_PNG_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnoe-autolearn-png")
    }

    private struct Harness: View {
        @State var selection: AutoLearnRepeatThreshold

        var body: some View {
            Form {
                Section {
                    Toggle("Auto-Learn Dictionary", isOn: .constant(true))
                    AutoLearnRepeatThresholdRow(selection: $selection) {
                        Image(systemName: "info.circle").imageScale(.medium).fontWeight(.semibold)
                    }
                    Toggle("Review with AI", isOn: .constant(false))
                } header: {
                    Text("Auto Learn")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(width: 520, height: 200)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        }
    }

    /// `ImageRenderer` draws nothing for a `Form`, whose rows are AppKit controls, so the view goes
    /// into an `NSHostingView` that is laid out and drawn into a bitmap. The view never gets a window.
    func testRenderSettingRow() throws {
        let size = NSSize(width: 520, height: 200)
        let hostingView = NSHostingView(rootView: Harness(selection: .twice))
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try png.write(to: outputDirectory.appendingPathComponent("auto-learn-setting.png"))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width))
    }
}
