import AppKit
import SwiftUI
import XCTest
import os

/// Renders the media rows of the Audio settings offscreen, with the note shown. Nothing is shown on screen and
/// nothing asks for a permission: the controller gets a fake meter that refuses. The folder comes from
/// `PNOE_MEDIA_PNG_DIR` (pass it to xcodebuild as `TEST_RUNNER_PNOE_MEDIA_PNG_DIR`) and defaults to a temporary
/// folder.
@MainActor
final class PauseMediaSettingPreviewTests: XCTestCase {
    private struct DenyingMeter: AudioLevelMeasuring {
        func measure(processes: [AudioProcess], includingOwnProcess: Bool, window: TimeInterval) async
            -> AudioLevelMeasurement
        { .unavailable(includingOwn: false) }
        func hasPermission() async -> Bool { false }
        func requestPermission() async -> Bool { false }
    }

    private struct Harness: View {
        @ObservedObject var playbackController: PlaybackController

        var body: some View {
            Form {
                Section {
                    Toggle("Mute Audio While Recording", isOn: .constant(false))
                    PauseMediaSettingRows(playbackController: playbackController)
                } header: {
                    Text("Recording Behavior")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(width: 560, height: 260)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        }
    }

    func testRenderMediaRowsAfterARefusal() async throws {
        let suite = "PnoePauseMediaPreview-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = PlaybackController(levelMeter: DenyingMeter(), defaults: defaults)
        controller.isPauseMediaEnabled = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(controller.needsPermission)

        let size = NSSize(width: 560, height: 260)
        let hostingView = NSHostingView(rootView: Harness(playbackController: controller))
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let directory: URL
        if let path = ProcessInfo.processInfo.environment["PNOE_MEDIA_PNG_DIR"], !path.isEmpty {
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnoe-media-png")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("one-media-switch.png"))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width))
    }
}
