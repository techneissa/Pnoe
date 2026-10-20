import AppKit
import SwiftUI
import XCTest

/// Renders the "Sync through iCloud Drive" rows offscreen: off, on with the last sync time, and the two
/// messages, in light and dark. Nothing is shown on screen. The folder comes from `PNOE_DRIVESYNC_PNG_DIR`
/// (pass it to xcodebuild as `TEST_RUNNER_PNOE_DRIVESYNC_PNG_DIR`) and defaults to a temporary folder.
@MainActor
final class DictionarySyncPreviewTests: XCTestCase {
    private var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["PNOE_DRIVESYNC_PNG_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnoe-drivesync-png")
    }

    private static let lastSync = Date(timeIntervalSince1970: 1_790_000_000 - 13 * 60)

    private struct Harness: View {
        let scheme: ColorScheme

        private func section(
            _ title: LocalizedStringKey, isOn: Bool, status: DictionarySyncStatus, symbol: MotionPhase
        ) -> some View {
            Section {
                DictionarySyncRow(isOn: .constant(isOn), status: status, symbolPhase: symbol) {
                    Image(systemName: "info.circle").imageScale(.medium).fontWeight(.semibold).padding(5)
                }
            } header: {
                Text(title)
            }
        }

        var body: some View {
            Form {
                section(
                    "Sync · off", isOn: false,
                    status: DictionarySyncStatus(phase: .off, lastSyncAt: nil), symbol: .idle)
                section(
                    "Sync · on, last sync time", isOn: true,
                    status: DictionarySyncStatus(phase: .idle, lastSyncAt: DictionarySyncPreviewTests.lastSync),
                    symbol: .idle)
                section(
                    "Sync · a pass just finished (the check)", isOn: true,
                    status: DictionarySyncStatus(phase: .idle, lastSyncAt: DictionarySyncPreviewTests.lastSync),
                    symbol: .finished)
                section(
                    "Sync · file can't be read", isOn: true,
                    status: DictionarySyncStatus(
                        phase: .unreadable, lastSyncAt: DictionarySyncPreviewTests.lastSync),
                    symbol: .failed)
                section(
                    "Sync · iCloud Drive is off", isOn: true,
                    status: DictionarySyncStatus(phase: .driveOff, lastSyncAt: nil), symbol: .failed)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(width: 460, height: 760)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
        }
    }

    /// `ImageRenderer` draws nothing for a `Form`, whose rows are AppKit controls, so the view goes into
    /// an `NSHostingView` that is laid out and drawn into a bitmap. The view never gets a window.
    private func render(_ scheme: ColorScheme, name: String) throws {
        let size = NSSize(width: 460, height: 760)
        let hostingView = NSHostingView(rootView: Harness(scheme: scheme))
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try png.write(to: outputDirectory.appendingPathComponent(name))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width))
    }

    func testRenderLight() throws { try render(.light, name: "drive-sync-light.png") }

    func testRenderDark() throws { try render(.dark, name: "drive-sync-dark.png") }
}
