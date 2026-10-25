import AppKit
import SwiftUI
import XCTest

/// Renders the "Read Replies Aloud" rows of Settings › Assistant and the stop button of the Assistant panel offscreen,
/// in dark mode. Nothing is shown on screen and nothing is spoken: the speaker runs on fakes. The folder comes from
/// `PNOE_REPLY_SPEECH_PNG_DIR` (pass it to xcodebuild as `TEST_RUNNER_PNOE_REPLY_SPEECH_PNG_DIR`) and defaults to a
/// temporary folder.
@MainActor
final class ReplySpeechPreviewTests: XCTestCase {
    private struct RowsHarness: View {
        @State var isEnabled: Bool
        @State var ollamaVoice = "emma"
        @State var appleVoice = ""
        let engine: ReplySpeechEngine

        var body: some View {
            Form {
                Section("Assistant") {
                    ReplySpeechSettingRows(
                        isEnabled: $isEnabled, ollamaVoice: $ollamaVoice, appleVoice: $appleVoice,
                        engine: engine,
                        appleVoices: [
                            SpeechVoiceChoice(id: "a", name: "Samantha", language: "English (United States)"),
                            SpeechVoiceChoice(id: "b", name: "Anna", language: "German (Germany)"),
                        ])
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(width: 620, height: 250)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        }
    }

    /// The follow-up row of the Assistant panel as it looks with the dark recorder theme: the field, the stop button
    /// while a reply is read, and the send button.
    private struct PanelRowHarness: View {
        @ObservedObject var speaker: ReplySpeaker
        let palette = RecorderPalette.dark

        var body: some View {
            HStack(spacing: 8) {
                Text("Ask a follow-up")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.ink.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(palette.ink.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                ReplySpeechStopButton(speaker: speaker, ink: palette.ink)

                Image(systemName: "paperplane.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(palette.ink.opacity(0.35))
                    .frame(width: 24, height: 24)
                    .background(palette.ink.opacity(0.10))
                    .clipShape(Circle())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(width: 420, height: 56)
            .background(Color.black)
            .environment(\.recorderPalette, palette)
            .environment(\.colorScheme, .dark)
        }
    }

    private var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["PNOE_REPLY_SPEECH_PNG_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnoe-reply-speech-png")
    }

    private func render<Content: View>(_ view: Content, size: NSSize, name: String) throws {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try png.write(to: outputDirectory.appendingPathComponent(name))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width))
    }

    func testRenderSettingsRowsDark() throws {
        let phonon = OllamaSpeechModel(name: "phonon", voices: ["default", "emma", "kent"])
        let size = NSSize(width: 620, height: 250)
        try render(RowsHarness(isEnabled: true, engine: .ollama(phonon)), size: size, name: "rows-ollama-dark.png")
        try render(RowsHarness(isEnabled: true, engine: .apple), size: size, name: "rows-apple-dark.png")
        try render(RowsHarness(isEnabled: false, engine: .apple), size: size, name: "rows-off-dark.png")
    }

    func testRenderStopButtonDarkWhileSpeakingAndAfter() async throws {
        let suite = "PnoeReplySpeechPreview-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: ReplySpeechSettings.enabledKey)

        let ollama = FakeOllamaSpeech(models: [])
        let speaker = ReplySpeaker(
            defaults: defaults, ollama: { ollama }, makeOutput: { FakePCMOutput() }, apple: HangingAppleSpeech())
        let size = NSSize(width: 420, height: 56)

        try render(PanelRowHarness(speaker: speaker), size: size, name: "panel-idle-dark.png")
        speaker.speakIfEnabled("The answer is forty-two.")
        XCTAssertTrue(speaker.isSpeaking)
        try render(PanelRowHarness(speaker: speaker), size: size, name: "panel-speaking-dark.png")
        speaker.stop(.stopButton)
        XCTAssertFalse(speaker.isSpeaking)
    }
}

/// An Apple voice that never finishes, so the speaker stays in the speaking state for the picture.
@MainActor
private final class HangingAppleSpeech: AppleSpeechOutput {
    private var waiter: CheckedContinuation<Void, Never>?

    func speak(_ text: String, voiceIdentifier: String?) async {
        await withCheckedContinuation { waiter = $0 }
    }

    func stop() {
        waiter?.resume()
        waiter = nil
    }
}
