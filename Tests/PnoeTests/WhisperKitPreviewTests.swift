import AppKit
import SwiftUI
import XCTest

/// Renders the WhisperKit model library rows and the "Use WhisperKit" setting offscreen. Nothing is
/// shown on screen. The folder comes from `PNOE_WHISPERKIT_PNG_DIR` (pass it to xcodebuild as
/// `TEST_RUNNER_PNOE_WHISPERKIT_PNG_DIR`) and defaults to a temporary folder.
@MainActor
final class WhisperKitPreviewTests: XCTestCase {
    private var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["PNOE_WHISPERKIT_PNG_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnoe-whisperkit-png")
    }

    private func dots(_ value: Double) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { index in
                Circle()
                    .fill(index < Int(value / 2) ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
            Text(String(format: "%.1f", value))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
        }
    }

    private func row(
        _ spec: WhisperKitModelSpec, installed: Bool = false, progress: WhisperKitDownloadProgress? = nil
    ) -> some View {
        WhisperKitModelRow(
            spec: spec, isInstalled: installed, progress: progress,
            onDownload: {}, onCancel: {}, onDelete: {}, onShowInFinder: {}
        ) {
            HStack(spacing: 3) { Text("Speed"); dots(spec.speed * 10) }.fixedSize()
            HStack(spacing: 3) { Text("Accuracy"); dots(spec.accuracy * 10) }.fixedSize()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private struct SettingHarness: View {
        @State var usage: WhisperKitUsage
        @State var fallback: String
        let power: PowerSource

        var body: some View {
            Form {
                WhisperKitSettingsSection(
                    usage: $usage,
                    fallbackModel: $fallback,
                    fallbackOptions: [
                        WhisperKitFallbackOption(id: "ggml-large-v3-turbo-q5_0", title: "Large v3 Turbo (Quantized)"),
                        WhisperKitFallbackOption(id: "parakeet-tdt-0.6b-v3", title: "Parakeet V3"),
                    ],
                    power: power
                ) {
                    Image(systemName: "info.circle").imageScale(.medium).fontWeight(.semibold)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(width: 560, height: 230)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        }
    }

    private func render<V: View>(_ view: V, size: NSSize, to name: String) throws {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try png.write(to: outputDirectory.appendingPathComponent(name))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width))
    }

    func testRenderModelLibraryRows() throws {
        let rows = VStack(spacing: 10) {
            row(WhisperKitCatalog.largeV3Turbo)
            row(
                WhisperKitCatalog.small,
                progress: WhisperKitDownloadProgress(fraction: 0.42, message: "Downloading...", isIndeterminate: false))
            row(WhisperKitCatalog.base, installed: true)
        }
        .padding(20)
        .frame(width: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)

        try render(rows, size: NSSize(width: 640, height: 400), to: "whisperkit-model-rows.png")
    }

    func testRenderSettingOnBattery() throws {
        try render(
            SettingHarness(usage: .automatic, fallback: "", power: .battery),
            size: NSSize(width: 560, height: 230), to: "whisperkit-setting-automatic-battery.png")
    }

    func testRenderSettingOnMains() throws {
        try render(
            SettingHarness(usage: .automatic, fallback: "parakeet-tdt-0.6b-v3", power: .mains),
            size: NSSize(width: 560, height: 230), to: "whisperkit-setting-automatic-mains.png")
    }
}
