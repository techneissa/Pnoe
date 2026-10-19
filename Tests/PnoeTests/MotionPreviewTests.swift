import AppKit
import SwiftUI
import XCTest

/// Renders the end states of the motion work as still pictures, offscreen, with a window-less
/// `NSHostingView` and `cacheDisplay(in:to:)` so native controls draw. Nothing is shown on screen
/// and nothing is clicked. The folder comes from `PNOE_MOTION_PNG_DIR` (pass it to xcodebuild as
/// `TEST_RUNNER_PNOE_MOTION_PNG_DIR`) and defaults to a temporary folder.
@MainActor
final class MotionPreviewTests: XCTestCase {
    private var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["PNOE_MOTION_PNG_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnoe-motion-png")
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
        for x in stride(from: 0, to: rep.pixelsWide, by: 5) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 5) {
                let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                let r = UInt32((c?.redComponent ?? 0) * 255)
                let g = UInt32((c?.greenComponent ?? 0) * 255)
                let b = UInt32((c?.blueComponent ?? 0) * 255)
                distinctColors.insert(r << 16 | g << 8 | b)
            }
        }
        XCTAssertGreaterThan(distinctColors.count, 4, "\(name) rendered blank")

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }

    // MARK: - Recorder

    private struct ModeStub: View {
        @Environment(\.recorderPalette) private var palette
        var body: some View {
            Image(systemName: "square.grid.2x2").font(.system(size: 13)).foregroundColor(palette.ink)
        }
    }

    private func recorder(_ state: RecordingState) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.25, green: 0.45, blue: 0.75), Color(red: 0.85, green: 0.55, blue: 0.4)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            MiniRecorderLayout(
                recordingState: state,
                liveContent: nil,
                theme: .dark,
                transcriptSize: .medium,
                placement: .bottom,
                hasAssistantResponse: false,
                showsCloseButton: false,
                levelHistoryProvider: { state == .recording ? RecorderIndicatorPreviewTests.speechHistory : LevelHistory() },
                levelDisplay: .bars,
                onRecordButtonTapped: {},
                onCloseTapped: {},
                modeButton: ModeStub(),
                assistantPanel: EmptyView()
            )
            .padding(.vertical, 8)
        }
    }

    func testRenderRecorderIdleAndRecording() throws {
        try render(recorder(.idle), size: CGSize(width: 420, height: 130), name: "recorder-idle")
        try render(recorder(.recording), size: CGSize(width: 420, height: 130), name: "recorder-recording")
    }

    // MARK: - Copy button

    private func copyButtons(copied: Bool) -> some View {
        HStack(spacing: 14) {
            CopyButtonFace(copied: copied)
            Text(copied ? "Copied" : "Copy").font(.callout)
        }
        .padding(20)
    }

    func testRenderCopyButtonBeforeAndAfterCopy() throws {
        try render(copyButtons(copied: false), size: CGSize(width: 180, height: 70), name: "copy-before")
        try render(copyButtons(copied: true), size: CGSize(width: 180, height: 70), name: "copy-after")
    }

    // MARK: - Downloads

    private func row(installed: Bool = false, failed: Bool = false, progress: WhisperKitDownloadProgress? = nil)
        -> some View
    {
        let spec = WhisperKitCatalog.small
        return WhisperKitModelRow(
            spec: spec, isInstalled: installed, progress: progress,
            onDownload: {}, onCancel: {}, onDelete: {}, onShowInFinder: {}, downloadFailed: failed
        ) {
            Text("Speed 8.0").fixedSize()
            Text("Accuracy 6.0").fixedSize()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .padding(12)
    }

    func testRenderDownloadFinishedFailedAndRunning() throws {
        try render(row(installed: true), size: CGSize(width: 640, height: 150), name: "download-finished")
        try render(row(failed: true), size: CGSize(width: 640, height: 150), name: "download-failed")
        try render(
            row(progress: WhisperKitDownloadProgress(fraction: 0.42, message: "Downloading...", isIndeterminate: false)),
            size: CGSize(width: 640, height: 150), name: "download-running")
    }

    // MARK: - Settings row hover

    private struct SettingsRows: View {
        let hovered: Bool
        @State private var expanded = false
        @State private var enabled = true

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                ExpandableSettingsRow(
                    isExpanded: $expanded, isEnabled: $enabled, label: "Smart formatting",
                    infoMessage: "Cleans up the text after transcription."
                ) {
                    Text("Options").foregroundStyle(.secondary)
                }
                Divider()
                ExpandableSettingsRow(title: "Advanced", isExpanded: .constant(false)) { EmptyView() }
            }
            .padding(16)
            .environment(\.motionHoverOverride, hovered)
        }
    }

    func testRenderSettingsRowHoveredAndNot() throws {
        try render(SettingsRows(hovered: false), size: CGSize(width: 420, height: 130), name: "settings-row-not-hovered")
        try render(SettingsRows(hovered: true), size: CGSize(width: 420, height: 130), name: "settings-row-hovered")
    }
}
