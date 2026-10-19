import SwiftUI

// The live preview in the Recorder Style settings: the real layouts, embedded in the settings
// view, fed with a synthetic input level and sample text. No window of its own and nothing on
// screen outside the settings window.

/// Everything the preview needs, as plain values. The settings view builds one from its stored
/// values on every change, so the preview follows each picker at once.
struct RecorderStylePreviewConfiguration: Equatable {
    var style: RecorderPanelStyle
    var theme: RecorderTheme
    var placement: MiniRecorderPlacement
    var slots: RecorderSideSlots
    var levelDisplay: RecorderLevelDisplay
    var showsLiveText: Bool
    var transcriptSize: LiveTranscriptSize
    var modeName: String

    static let sampleText = "Move the release candidate to staging once the migration finishes."

    /// The line the live preview shows: the sample text when live text is on and the style
    /// carries it. The dot has no live line.
    var liveContent: LiveTranscriptContent? {
        guard showsLiveText, style.showsLiveTranscript else { return nil }
        return .text(Self.sampleText)
    }

    /// Height that fits the tallest state of any style, so the settings page does not jump when
    /// the style changes.
    static let height: CGFloat = 176
}

struct RecorderStylePreview: View {
    let configuration: RecorderStylePreviewConfiguration
    /// Level history and clock for the current frame. The settings view uses the synthetic
    /// ones, the offscreen renders fixed ones.
    var levelHistoryProvider: () -> LevelHistory = {
        SyntheticLevels.history(endingAt: Date().timeIntervalSinceReferenceDate)
    }
    var clockProvider: () -> RecordingClock = { RecordingClock.looping(period: 90, at: Date()) }

    private let notchSize = CGSize(width: 150, height: 32)

    var body: some View {
        ZStack(alignment: .top) {
            backdrop
            layout
                .padding(.top, configuration.style == .notch ? 0 : 10)
                .padding(.bottom, 10)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: RecorderStylePreviewConfiguration.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Recorder preview"))
    }

    /// A stand-in for the desktop, so the translucent theme has something to show through.
    private var backdrop: some View {
        LinearGradient(
            colors: [Color(red: 0.25, green: 0.45, blue: 0.75), Color(red: 0.85, green: 0.55, blue: 0.4)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    @ViewBuilder
    private var layout: some View {
        switch configuration.style {
        case .notch:
            NotchRecorderLayout(
                recordingState: .recording,
                liveContent: configuration.liveContent,
                theme: configuration.theme,
                transcriptSize: configuration.transcriptSize,
                isAlwaysVisible: false,
                hasAssistantResponse: false,
                showsCloseButton: false,
                notchWidth: notchSize.width,
                notchHeight: notchSize.height,
                levelHistoryProvider: levelHistoryProvider,
                levelDisplay: configuration.levelDisplay,
                slots: configuration.slots,
                modeName: configuration.modeName,
                clockProvider: clockProvider,
                onRecordButtonTapped: {},
                onCloseTapped: {},
                modeButton: PreviewModeIcon(size: 20),
                assistantPanel: EmptyView()
            )
        case .mini, .pill:
            MiniRecorderLayout(
                recordingState: .recording,
                liveContent: configuration.liveContent,
                theme: configuration.theme,
                transcriptSize: configuration.transcriptSize,
                placement: configuration.placement,
                hasAssistantResponse: false,
                showsCloseButton: false,
                levelHistoryProvider: levelHistoryProvider,
                levelDisplay: configuration.levelDisplay,
                variant: configuration.style == .pill ? .pill : .mini,
                slots: configuration.slots,
                modeName: configuration.modeName,
                clockProvider: clockProvider,
                isPreview: true,
                onRecordButtonTapped: {},
                onCloseTapped: {},
                modeButton: PreviewModeIcon(size: 22),
                assistantPanel: EmptyView()
            )
        case .dot:
            DotRecorderLayout(
                recordingState: .recording,
                theme: configuration.theme,
                placement: configuration.placement,
                levelHistoryProvider: levelHistoryProvider,
                clockProvider: clockProvider,
                isPreview: true,
                onRecordButtonTapped: {}
            )
        }
    }
}

/// The mode button's face without its popover: the preview must not open anything.
private struct PreviewModeIcon: View {
    @Environment(\.recorderPalette) private var palette
    let size: CGFloat

    var body: some View {
        Image(systemName: "square.grid.2x2")
            .font(.system(size: 13))
            .foregroundColor(palette.ink)
            .frame(width: size)
    }
}
