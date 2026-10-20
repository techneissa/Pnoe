import AppKit
import SwiftUI
import XCTest

/// Renders the sync rows offscreen: no file chosen, a file with the last result, a pass running, a
/// problem, and the question before entries are removed, in light and dark. Nothing is shown on screen.
/// The folder comes from `PNOE_DRIVESYNC_PNG_DIR` (pass it to xcodebuild as
/// `TEST_RUNNER_PNOE_DRIVESYNC_PNG_DIR`) and defaults to a temporary folder.
@MainActor
final class DictionarySyncPreviewTests: XCTestCase {
    private var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["PNOE_DRIVESYNC_PNG_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnoe-drivesync-png")
    }

    private static let now = Date(timeIntervalSince1970: 1_790_000_000)
    private static let file = DictionarySyncFileDescription(name: "Dictionary Sync.json", folder: "iCloud Drive/Pnoe")

    private struct SectionHarness: View {
        let scheme: ColorScheme

        private func syncSection(
            _ title: LocalizedStringKey, file: DictionarySyncFileDescription?, result: DictionarySyncResultLine?,
            working: Bool = false, symbol: MotionPhase = .idle
        ) -> some View {
            Section {
                DictionarySyncRow(
                    file: file, result: result, isWorking: working, canSync: file != nil && !working,
                    symbolPhase: symbol, now: DictionarySyncPreviewTests.now,
                    chooseExisting: {}, chooseNew: {}, syncNow: {}, cancel: {}
                ) {
                    Image(systemName: "info.circle").imageScale(.medium).fontWeight(.semibold).padding(5)
                }
            } header: {
                Text(title)
            }
        }

        var body: some View {
            Form {
                syncSection("Sync · no file chosen", file: nil, result: nil)
                syncSection(
                    "Sync · file chosen, last result", file: DictionarySyncPreviewTests.file,
                    result: DictionarySyncResultLine(
                        kind: .success(added: 4, updated: 1, removed: 0),
                        at: DictionarySyncPreviewTests.now.addingTimeInterval(-120)))
                syncSection(
                    "Sync · just finished (the check)", file: DictionarySyncPreviewTests.file,
                    result: DictionarySyncResultLine(
                        kind: .success(added: 4, updated: 1, removed: 0), at: DictionarySyncPreviewTests.now),
                    symbol: .finished)
                syncSection(
                    "Sync · a pass is running", file: DictionarySyncPreviewTests.file, result: nil,
                    working: true, symbol: .running)
                syncSection(
                    "Sync · error", file: DictionarySyncPreviewTests.file,
                    result: DictionarySyncResultLine(
                        kind: .failure(DictionarySyncController.message(for: .unreadableFile)),
                        at: DictionarySyncPreviewTests.now),
                    symbol: .failed)
                Section {
                    DictionaryTransferRow(
                        title: "Export Dictionary", actionTitle: "Export", rememberedName: "Backups", change: {},
                        action: {})
                    DictionaryTransferRow(
                        title: "Import Dictionary", actionTitle: "Import", rememberedName: "Pnoe_Dictionary.json",
                        change: {}, action: {})
                } header: {
                    Text("Dictionary Data · folder and file remembered")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(width: 520, height: 1000)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
        }
    }

    private struct ReviewHarness: View {
        let scheme: ColorScheme

        var body: some View {
            DictionarySyncReviewSheet(
                review: DictionarySyncReview(
                    removals: ["Kubernetes", "teh → the", "my email", "Zeta", "recieve → receive", "sig", "Beta"]
                        .enumerated().map {
                            DictionarySyncRemoval(
                                key: DictionarySyncKey(kind: .vocabulary, id: "\($0.offset)"), title: $0.element)
                        }),
                onRemove: {}, onKeep: {}
            )
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
        }
    }

    /// `ImageRenderer` draws nothing for a `Form`, whose rows are AppKit controls, so the view goes into
    /// an `NSHostingView` that is laid out and drawn into a bitmap. The view never gets a window.
    private func render<Content: View>(_ view: Content, size: NSSize, scheme: ColorScheme, name: String) throws {
        let hostingView = NSHostingView(rootView: view)
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

    func testRenderSectionLight() throws {
        try render(SectionHarness(scheme: .light), size: NSSize(width: 520, height: 1000), scheme: .light, name: "sync-section-light.png")
    }

    func testRenderSectionDark() throws {
        try render(SectionHarness(scheme: .dark), size: NSSize(width: 520, height: 1000), scheme: .dark, name: "sync-section-dark.png")
    }

    func testRenderReviewLight() throws {
        try render(ReviewHarness(scheme: .light), size: NSSize(width: 400, height: 300), scheme: .light, name: "sync-review-light.png")
    }

    func testRenderReviewDark() throws {
        try render(ReviewHarness(scheme: .dark), size: NSSize(width: 400, height: 300), scheme: .dark, name: "sync-review-dark.png")
    }
}
