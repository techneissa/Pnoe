import AppKit
import SwiftUI
import XCTest

/// Renders the recorder layouts offscreen with `ImageRenderer`, one PNG per theme, style and
/// transcript state, at 2x. Nothing is shown on screen. The folder comes from the
/// `PNOE_INDICATOR_PNG_DIR` variable (pass it to xcodebuild as `TEST_RUNNER_PNOE_INDICATOR_PNG_DIR`)
/// and defaults to a temporary folder.
@MainActor
final class RecorderIndicatorPreviewTests: XCTestCase {
    private static let sampleTranscript =
        "so the plan for tomorrow is to move the release candidate to the staging cluster once the migration finishes and then ask the team to run the smoke tests"

    private struct ModeStub: View {
        @Environment(\.recorderPalette) private var palette

        var body: some View {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 13))
                .foregroundColor(palette.ink)
        }
    }

    private var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["PNOE_INDICATOR_PNG_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnoe-indicator-png")
    }

    private func backdrop<Content: View>(width: CGFloat, height: CGFloat, @ViewBuilder content: () -> Content)
        -> some View
    {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color(red: 0.25, green: 0.45, blue: 0.75), Color(red: 0.85, green: 0.55, blue: 0.4)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            content()
        }
        .frame(width: width, height: height)
    }

    private func miniView(theme: RecorderTheme, transcript: String?, placement: MiniRecorderPlacement) -> some View {
        backdrop(width: 420, height: 130) {
            MiniRecorderLayout(
                recordingState: .recording,
                liveContent: transcript.map { LiveTranscriptContent.text($0) },
                theme: theme,
                transcriptSize: .medium,
                placement: placement,
                hasAssistantResponse: false,
                showsCloseButton: false,
                audioMeterProvider: { AudioMeter(averagePower: 0.55, peakPower: 0.7) },
                onRecordButtonTapped: {},
                onCloseTapped: {},
                modeButton: ModeStub(),
                assistantPanel: EmptyView()
            )
            .padding(.vertical, 8)
        }
    }

    private func notchView(theme: RecorderTheme, transcript: String?) -> some View {
        backdrop(width: 520, height: 130) {
            NotchRecorderLayout(
                recordingState: .recording,
                liveContent: transcript.map { LiveTranscriptContent.text($0) },
                theme: theme,
                transcriptSize: .medium,
                isAlwaysVisible: false,
                hasAssistantResponse: false,
                showsCloseButton: false,
                notchWidth: 180,
                notchHeight: 32,
                audioMeterProvider: { AudioMeter(averagePower: 0.55, peakPower: 0.7) },
                onRecordButtonTapped: {},
                onCloseTapped: {},
                modeButton: ModeStub(),
                assistantPanel: EmptyView()
            )
        }
    }

    private func writePNG<V: View>(_ view: V, name: String) throws -> URL {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, name)
        let tiff = try XCTUnwrap(image.tiffRepresentation, name)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff), name)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]), name)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let url = outputDirectory.appendingPathComponent("\(name).png")
        try png.write(to: url)
        XCTAssertEqual(bitmap.pixelsWide, Int(image.size.width * 2), name)
        return url
    }

    func testRenderEveryThemeAndStyle() throws {
        var written: [URL] = []
        for theme in RecorderTheme.allCases {
            for (label, transcript) in [("transcript", Self.sampleTranscript as String?), ("idle", nil)] {
                written.append(
                    try writePNG(
                        miniView(theme: theme, transcript: transcript, placement: .bottom),
                        name: "mini-\(theme.rawValue)-\(label)"))
                written.append(
                    try writePNG(notchView(theme: theme, transcript: transcript), name: "notch-\(theme.rawValue)-\(label)"))
            }
        }
        written.append(
            try writePNG(
                miniView(theme: .dark, transcript: Self.sampleTranscript, placement: .top),
                name: "mini-dark-transcript-top"))
        written.append(
            try writePNG(
                backdrop(width: 420, height: 130) {
                    MiniRecorderLayout(
                        recordingState: .recording, liveContent: .listening, theme: .dark, transcriptSize: .medium,
                        placement: .bottom, hasAssistantResponse: false, showsCloseButton: false,
                        audioMeterProvider: { AudioMeter(averagePower: 0.1, peakPower: 0.2) },
                        onRecordButtonTapped: {}, onCloseTapped: {}, modeButton: ModeStub(), assistantPanel: EmptyView()
                    )
                    .padding(.vertical, 8)
                }, name: "mini-dark-listening"))

        XCTAssertEqual(written.count, 14)
        for url in written {
            let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            XCTAssertGreaterThan(size, 1000, url.lastPathComponent)
        }
    }
}
