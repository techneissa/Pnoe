import AppKit
import SwiftUI
import XCTest

/// Renders every recorder style (Mini, Pill, Dot, Notch) in processing, done and failed, dark and
/// light, as still pictures, offscreen, with a window-less `NSHostingView` and `cacheDisplay(in:to:)`.
/// Nothing is shown on screen and nothing is clicked. The folder comes from `PNOE_OUTCOME_PNG_DIR`
/// (pass it to xcodebuild as `TEST_RUNNER_PNOE_OUTCOME_PNG_DIR`) and defaults to a temporary folder.
@MainActor
final class RecorderOutcomeRenderTests: XCTestCase {
    private static let clock = RecordingClock(startedAt: 100, endedAt: 107)

    private var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["PNOE_OUTCOME_PNG_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnoe-outcome-png")
    }

    private struct ModeStub: View {
        @Environment(\.recorderPalette) private var palette
        var body: some View {
            Image(systemName: "square.grid.2x2").font(.system(size: 13)).foregroundColor(palette.ink)
        }
    }

    private func backdrop<Content: View>(size: CGSize, dark: Bool, @ViewBuilder content: () -> Content)
        -> some View
    {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: dark
                    ? [Color(red: 0.25, green: 0.45, blue: 0.75), Color(red: 0.85, green: 0.55, blue: 0.4)]
                    : [Color(red: 0.55, green: 0.7, blue: 0.9), Color(red: 0.95, green: 0.8, blue: 0.65)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            content()
        }
        .frame(width: size.width, height: size.height)
    }

    private func recorder(_ style: RecorderPanelStyle, state: RecordingState, theme: RecorderTheme) -> (
        view: AnyView, size: CGSize
    ) {
        let history = { RecorderIndicatorPreviewTests.speechHistory }
        switch style {
        case .mini, .pill:
            let size = CGSize(width: 360, height: 70)
            let view = backdrop(size: size, dark: theme == .dark) {
                MiniRecorderLayout(
                    recordingState: state, liveContent: nil, theme: theme, transcriptSize: .medium,
                    placement: .bottom, hasAssistantResponse: false, showsCloseButton: false,
                    levelHistoryProvider: history, levelDisplay: .bars, variant: style == .pill ? .pill : .mini,
                    slots: .defaults(for: style), modeName: "Notes", clockProvider: { Self.clock },
                    onRecordButtonTapped: {}, onCloseTapped: {},
                    modeButton: ModeStub(), assistantPanel: EmptyView()
                )
                .padding(.vertical, 8)
            }
            return (AnyView(view), size)
        case .dot:
            let size = CGSize(width: 200, height: 60)
            let view = backdrop(size: size, dark: theme == .dark) {
                DotRecorderLayout(
                    recordingState: state, theme: theme, placement: .bottom, levelHistoryProvider: history,
                    clockProvider: { Self.clock }, onRecordButtonTapped: {}
                )
                .padding(.vertical, 8)
            }
            return (AnyView(view), size)
        case .notch:
            let size = CGSize(width: 560, height: 60)
            let view = backdrop(size: size, dark: theme == .dark) {
                NotchRecorderLayout(
                    recordingState: state, liveContent: nil, theme: theme, transcriptSize: .medium,
                    isAlwaysVisible: false, hasAssistantResponse: false, showsCloseButton: false,
                    notchWidth: 180, notchHeight: 32, levelHistoryProvider: history, levelDisplay: .bars,
                    slots: .defaults(for: .notch), modeName: "Notes", clockProvider: { Self.clock },
                    onRecordButtonTapped: {}, onCloseTapped: {},
                    modeButton: ModeStub(), assistantPanel: EmptyView()
                )
            }
            return (AnyView(view), size)
        }
    }

    private func render(_ view: AnyView, size: CGSize, name: String, dark: Bool, showsRed: Bool, scale: CGFloat = 3) throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        let pixelsWide = Int(size.width * scale)
        let pixelsHigh = Int(size.height * scale)
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
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
        XCTAssertGreaterThan(distinctColors.count, 4, "\(name) rendered blank")

        // The error symbol is red; nothing else in a recorder is.
        var redPixels = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent > 0.8 && c.greenComponent < 0.3 && c.blueComponent < 0.3 { redPixels += 1 }
            }
        }
        if showsRed {
            XCTAssertGreaterThan(redPixels, 20, "\(name) has no red error symbol")
        } else {
            XCTAssertEqual(redPixels, 0, "\(name) shows red")
        }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }

    func testRenderProcessingDoneAndFailedForEveryStyle() throws {
        let states: [(String, RecordingState)] = [
            ("processing", .transcribing), ("done", .done), ("failed", .failed),
        ]
        var count = 0
        for style in [RecorderPanelStyle.mini, .pill, .dot, .notch] {
            for theme in [RecorderTheme.dark, .light] {
                for (label, state) in states {
                    let (view, size) = recorder(style, state: state, theme: theme)
                    try render(
                        view, size: size, name: "\(style.rawValue)-\(theme.rawValue)-\(label)",
                        dark: theme == .dark, showsRed: state == .failed)
                    count += 1
                }
            }
        }
        XCTAssertEqual(count, 24)
    }
}
