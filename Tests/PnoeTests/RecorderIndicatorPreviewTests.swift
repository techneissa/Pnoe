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

    private func miniView(
        theme: RecorderTheme, transcript: String?, placement: MiniRecorderPlacement,
        display: RecorderLevelDisplay = .bars
    ) -> some View {
        backdrop(width: 420, height: 130) {
            MiniRecorderLayout(
                recordingState: .recording,
                liveContent: transcript.map { LiveTranscriptContent.text($0) },
                theme: theme,
                transcriptSize: .medium,
                placement: placement,
                hasAssistantResponse: false,
                showsCloseButton: false,
                levelHistoryProvider: { Self.speechHistory },
                levelDisplay: display,
                onRecordButtonTapped: {},
                onCloseTapped: {},
                modeButton: ModeStub(),
                assistantPanel: EmptyView()
            )
            .padding(.vertical, 8)
        }
    }

    private func notchView(theme: RecorderTheme, transcript: String?, display: RecorderLevelDisplay = .bars)
        -> some View
    {
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
                levelHistoryProvider: { Self.speechHistory },
                levelDisplay: display,
                onRecordButtonTapped: {},
                onCloseTapped: {},
                modeButton: ModeStub(),
                assistantPanel: EmptyView()
            )
        }
    }

    /// A fixed, speech-like input: nine syllables with pauses over room noise, two seconds
    /// at 30 samples a second. It goes through the same dB mapping and smoothing the recorder
    /// uses, so the renders show what a recording looks like.
    static let speechHistory: LevelHistory = {
        let syllables: [(start: Int, length: Int, peakDecibels: Float)] = [
            (2, 5, -27), (8, 4, -23), (13, 6, -20), (21, 3, -31),
            (30, 5, -24), (36, 4, -19), (49, 3, -27), (52, 5, -21), (58, 2, -30),
        ]
        var history = LevelHistory()
        var smoothed: Float = 0
        for index in 0..<RecorderLevelMetrics.historyCapacity {
            var decibels = -55 + 3 * Float(sin(Double(index) * 1.7))
            for syllable in syllables where (syllable.start..<syllable.start + syllable.length).contains(index) {
                let position = Float(index - syllable.start) + 0.5
                let envelope = Float(sin(Double.pi * Double(position / Float(syllable.length))))
                decibels = max(decibels, -54 + (syllable.peakDecibels + 54) * envelope)
            }
            smoothed = LevelMapping.smoothed(previous: smoothed, next: LevelMapping.level(fromDecibels: decibels))
            history.append(smoothed)
        }
        return history
    }()

    private func writePNG<V: View>(_ view: V, name: String, scale: CGFloat = 2, folder: String? = nil) throws -> URL {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.nsImage, name)
        let tiff = try XCTUnwrap(image.tiffRepresentation, name)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff), name)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]), name)
        let directory = folder.map { outputDirectory.appendingPathComponent($0, isDirectory: true) } ?? outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        try png.write(to: url)
        XCTAssertEqual(bitmap.pixelsWide, Int(image.size.width * scale), name)
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
                        levelHistoryProvider: { Self.speechHistory }, levelDisplay: .bars,
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

    private func visualizerOnTheme(
        _ theme: RecorderTheme, display: RecorderLevelDisplay, history: LevelHistory, reduceMotion: Bool
    ) -> some View {
        AudioVisualizer(
            levelHistoryProvider: { history }, color: theme.palette.ink, display: display,
            reduceMotionOverride: reduceMotion
        )
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(RecorderThemeBackground(theme: theme))
    }

    func testRenderLevelDisplays() throws {
        var written: [URL] = []
        for theme in RecorderTheme.allCases {
            for display in RecorderLevelDisplay.allCases {
                let name = "\(display.rawValue)-\(theme.rawValue)"
                written.append(
                    try writePNG(
                        miniView(theme: theme, transcript: nil, placement: .bottom, display: display),
                        name: "mini-\(name)", scale: 3, folder: "levels"))
                written.append(
                    try writePNG(
                        notchView(theme: theme, transcript: nil, display: display),
                        name: "notch-\(name)", scale: 3, folder: "levels"))
            }
            written.append(
                try writePNG(
                    visualizerOnTheme(theme, display: .bars, history: Self.speechHistory, reduceMotion: true),
                    name: "reduce-motion-\(theme.rawValue)", scale: 3, folder: "levels"))
        }
        for display in RecorderLevelDisplay.allCases {
            written.append(
                try writePNG(
                    visualizerOnTheme(.dark, display: display, history: LevelHistory(), reduceMotion: false),
                    name: "silence-\(display.rawValue)-dark", scale: 3, folder: "levels"))
        }

        XCTAssertEqual(written.count, 17)
        for url in written {
            let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            XCTAssertGreaterThan(size, 500, url.lastPathComponent)
        }
    }
}
