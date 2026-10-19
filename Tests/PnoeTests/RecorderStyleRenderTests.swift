import AppKit
import SwiftUI
import XCTest

/// Renders the Pill and Dot styles, two side-slot variants and the Recorder Style settings
/// section offscreen, one PNG each, at 2x. Nothing is shown on screen: the images come from
/// `ImageRenderer` and from an `NSHostingView` that is never put in a window. The folder comes
/// from `PNOE_INDICATOR_PNG_DIR` (pass it to xcodebuild as `TEST_RUNNER_PNOE_INDICATOR_PNG_DIR`)
/// and defaults to a temporary folder.
@MainActor
final class RecorderStyleRenderTests: XCTestCase {
    private static let sampleText = RecorderStylePreviewConfiguration.sampleText

    /// 7 seconds into a take, frozen, so every render shows the same "0:07".
    private static let clock = RecordingClock(startedAt: 100, endedAt: 107)

    private struct ModeStub: View {
        @Environment(\.recorderPalette) private var palette

        var body: some View {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 13))
                .foregroundColor(palette.ink)
        }
    }

    private var outputDirectory: URL {
        let base: URL
        if let path = ProcessInfo.processInfo.environment["PNOE_INDICATOR_PNG_DIR"], !path.isEmpty {
            base = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnoe-indicator-png")
        }
        return base.appendingPathComponent("styles", isDirectory: true)
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

    private func pillView(
        theme: RecorderTheme, transcript: String? = nil, slots: RecorderSideSlots = .defaults(for: .pill),
        state: RecordingState = .recording
    ) -> some View {
        backdrop(width: 360, height: transcript == nil ? 70 : 130) {
            MiniRecorderLayout(
                recordingState: state,
                liveContent: transcript.map { LiveTranscriptContent.text($0) },
                theme: theme, transcriptSize: .medium, placement: .bottom,
                hasAssistantResponse: false, showsCloseButton: false,
                levelHistoryProvider: { RecorderIndicatorPreviewTests.speechHistory },
                levelDisplay: .bars, variant: .pill, slots: slots, modeName: "Notes",
                clockProvider: { Self.clock },
                onRecordButtonTapped: {}, onCloseTapped: {},
                modeButton: ModeStub(), assistantPanel: EmptyView()
            )
            .padding(.vertical, 8)
        }
    }

    private func miniView(theme: RecorderTheme = .dark, slots: RecorderSideSlots = .defaults(for: .mini)) -> some View {
        backdrop(width: 360, height: 70) {
            MiniRecorderLayout(
                recordingState: .recording, liveContent: nil, theme: theme, transcriptSize: .medium,
                placement: .bottom, hasAssistantResponse: false, showsCloseButton: false,
                levelHistoryProvider: { RecorderIndicatorPreviewTests.speechHistory },
                levelDisplay: .bars, slots: slots, modeName: "Notes", clockProvider: { Self.clock },
                onRecordButtonTapped: {}, onCloseTapped: {},
                modeButton: ModeStub(), assistantPanel: EmptyView()
            )
            .padding(.vertical, 8)
        }
    }

    private func notchView(theme: RecorderTheme = .dark, slots: RecorderSideSlots = .defaults(for: .notch)) -> some View {
        backdrop(width: 560, height: 60) {
            NotchRecorderLayout(
                recordingState: .recording, liveContent: nil, theme: theme, transcriptSize: .medium,
                isAlwaysVisible: false, hasAssistantResponse: false, showsCloseButton: false,
                notchWidth: 180, notchHeight: 32,
                levelHistoryProvider: { RecorderIndicatorPreviewTests.speechHistory },
                levelDisplay: .bars, slots: slots, modeName: "Notes", clockProvider: { Self.clock },
                onRecordButtonTapped: {}, onCloseTapped: {},
                modeButton: ModeStub(), assistantPanel: EmptyView()
            )
        }
    }

    private func dotView(theme: RecorderTheme, state: RecordingState = .recording) -> some View {
        backdrop(width: 200, height: 60) {
            DotRecorderLayout(
                recordingState: state, theme: theme, placement: .bottom,
                levelHistoryProvider: { RecorderIndicatorPreviewTests.speechHistory },
                clockProvider: { Self.clock }, onRecordButtonTapped: {}
            )
            .padding(.vertical, 8)
        }
    }

    private func png(from rep: NSBitmapImageRep, name: String) throws -> URL {
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]), name)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let url = outputDirectory.appendingPathComponent("\(name).png")
        try data.write(to: url)
        return url
    }

    private func writePNG<V: View>(_ view: V, name: String, scale: CGFloat = 2) throws -> URL {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.nsImage, name)
        let tiff = try XCTUnwrap(image.tiffRepresentation, name)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff), name)
        XCTAssertEqual(rep.pixelsWide, Int(image.size.width * scale), name)
        return try png(from: rep, name: name)
    }

    private func checkWritten(_ urls: [URL], minimumBytes: Int = 600) throws {
        for url in urls {
            let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            XCTAssertGreaterThan(size, minimumBytes, url.lastPathComponent)
        }
    }

    func testRenderPillAndDot() throws {
        var written: [URL] = []
        for theme in RecorderTheme.allCases {
            written.append(try writePNG(pillView(theme: theme), name: "pill-\(theme.rawValue)", scale: 3))
            written.append(try writePNG(dotView(theme: theme), name: "dot-\(theme.rawValue)", scale: 3))
            written.append(try writePNG(miniView(theme: theme), name: "mini-\(theme.rawValue)", scale: 3))
            written.append(try writePNG(notchView(theme: theme), name: "notch-\(theme.rawValue)", scale: 3))
        }
        written.append(
            try writePNG(pillView(theme: .dark, transcript: Self.sampleText), name: "pill-dark-transcript", scale: 3))
        written.append(
            try writePNG(pillView(theme: .translucent, transcript: Self.sampleText), name: "pill-translucent-transcript", scale: 3))
        written.append(
            try writePNG(pillView(theme: .light, transcript: Self.sampleText), name: "pill-light-transcript", scale: 3))
        written.append(try writePNG(dotView(theme: .dark, state: .transcribing), name: "dot-dark-processing", scale: 3))
        written.append(try writePNG(dotView(theme: .dark, state: .idle), name: "dot-dark-idle", scale: 3))
        XCTAssertEqual(written.count, 17)
        try checkWritten(written)
    }

    func testRenderSideSlotVariants() throws {
        var written: [URL] = []
        // The level meter in a side slot leaves the centre empty.
        written.append(
            try writePNG(
                miniView(slots: RecorderSideSlots(left: .timer, right: .level)), name: "mini-slots-timer-level",
                scale: 3))
        written.append(
            try writePNG(
                miniView(slots: RecorderSideSlots(left: .modeName, right: .timer)), name: "mini-slots-mode-timer",
                scale: 3))
        written.append(
            try writePNG(
                notchView(slots: RecorderSideSlots(left: .timer, right: .modeName)), name: "notch-slots-timer-mode",
                scale: 3))
        written.append(
            try writePNG(
                pillView(theme: .dark, slots: RecorderSideSlots(left: .modeName, right: .timer)),
                name: "pill-slots-mode-timer", scale: 3))
        // Wider than its slots, so each slot shows at its own end of the bar.
        written.append(
            try writePNG(
                pillView(
                    theme: .dark, transcript: Self.sampleText,
                    slots: RecorderSideSlots(left: .timer, right: .modeName)),
                name: "pill-slots-timer-mode-wide", scale: 3))
        try checkWritten(written)
    }

    /// The settings page's Recorder Style rows around the real preview view. `SettingsView`
    /// needs the app's environment objects, so the rows here repeat its labels and order with
    /// fixed values; the preview is the view the settings page embeds.
    private struct SettingsSectionMock: View {
        let configuration: RecorderStylePreviewConfiguration

        var body: some View {
            Form {
                Section("Interface") {
                    Picker("Recorder Style", selection: .constant(configuration.style)) {
                        ForEach(RecorderPanelStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.menu)

                    RecorderStylePreview(
                        configuration: configuration,
                        levelHistoryProvider: { RecorderIndicatorPreviewTests.speechHistory },
                        clockProvider: { RecorderStyleRenderTests.clock }
                    )
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))

                    Picker("Recorder Theme", selection: .constant(configuration.theme)) {
                        ForEach(RecorderTheme.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.menu)

                    Picker("Level Display", selection: .constant(configuration.levelDisplay)) {
                        ForEach(RecorderLevelDisplay.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.menu)

                    if configuration.style.hasSideSlots {
                        Picker("Left Side", selection: .constant(configuration.slots.left)) {
                            ForEach(RecorderSlotContent.allCases) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.menu)
                        Picker("Right Side", selection: .constant(configuration.slots.right)) {
                            ForEach(RecorderSlotContent.allCases) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }

                    Picker("Position", selection: .constant(configuration.placement)) {
                        ForEach(MiniRecorderPlacement.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.menu)

                    Toggle("Live Text Display", isOn: .constant(configuration.showsLiveText))

                    if !configuration.style.showsLiveTranscript {
                        Text("The Dot shows no live text. While the assistant is open it expands to the Pill, which does.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        }
    }

    /// Draws a view into a bitmap through an `NSHostingView` that is never put in a window.
    private func hostedPNG<V: View>(_ view: V, size: CGSize, name: String) throws -> URL {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds), name)
        host.cacheDisplay(in: host.bounds, to: rep)
        return try png(from: rep, name: name)
    }

    func testRenderSettingsSectionWithPreview() throws {
        func config(_ style: RecorderPanelStyle, theme: RecorderTheme = .dark) -> RecorderStylePreviewConfiguration {
            RecorderStylePreviewConfiguration(
                style: style, theme: theme, placement: .bottom, slots: .defaults(for: style),
                levelDisplay: .bars, showsLiveText: true, transcriptSize: .medium, modeName: "Notes")
        }
        var written: [URL] = []
        written.append(
            try hostedPNG(
                SettingsSectionMock(configuration: config(.pill)), size: CGSize(width: 560, height: 560),
                name: "settings-pill"))
        written.append(
            try hostedPNG(
                SettingsSectionMock(configuration: config(.dot, theme: .light)), size: CGSize(width: 560, height: 520),
                name: "settings-dot-light"))
        written.append(
            try hostedPNG(
                SettingsSectionMock(configuration: config(.notch, theme: .translucent)),
                size: CGSize(width: 560, height: 560), name: "settings-notch-translucent"))
        try checkWritten(written, minimumBytes: 5000)
    }
}
