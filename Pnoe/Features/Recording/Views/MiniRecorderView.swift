import SwiftUI

/// The view of the Mini, Pill and Dot styles, which share one panel.
struct MiniRecorderView<S: RecorderStateProvider & ObservableObject>: View {
    let style: RecorderPanelStyle
    @ObservedObject var stateProvider: S
    @ObservedObject var recorder: Recorder
    @ObservedObject var assistantSession: AssistantSession
    let onRecordButtonTapped: () -> Void
    let onCloseTapped: () -> Void
    let onAssistantFollowUp: (String) -> Void
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = true
    @AppStorage(RecorderDisplaySettingsKeys.liveTranscriptSize) private var liveTranscriptSizeRaw = LiveTranscriptSize.medium.rawValue
    @AppStorage(RecorderDisplaySettingsKeys.theme) private var themeRaw = RecorderTheme.dark.rawValue
    @AppStorage(RecorderDisplaySettingsKeys.levelDisplay) private var levelDisplayRaw = RecorderLevelDisplay.bars.rawValue
    @AppStorage(RecorderDisplaySettingsKeys.miniPlacement) private var placementRaw = MiniRecorderPlacement.bottom.rawValue
    @AppStorage private var slotsRaw: String
    @ObservedObject private var modeManager = ModeManager.shared

    init(
        style: RecorderPanelStyle,
        stateProvider: S,
        recorder: Recorder,
        assistantSession: AssistantSession,
        onRecordButtonTapped: @escaping () -> Void,
        onCloseTapped: @escaping () -> Void,
        onAssistantFollowUp: @escaping (String) -> Void
    ) {
        self.style = style
        self.stateProvider = stateProvider
        self.recorder = recorder
        self.assistantSession = assistantSession
        self.onRecordButtonTapped = onRecordButtonTapped
        self.onCloseTapped = onCloseTapped
        self.onAssistantFollowUp = onAssistantFollowUp
        // A dot has no slots; when the assistant opens it shows the pill, with the pill's slots.
        let slotStyle = style == .dot ? RecorderPanelStyle.pill : style
        _slotsRaw = AppStorage(
            wrappedValue: RecorderSideSlots.defaults(for: slotStyle).storedValue,
            RecorderSideSlots.storageKey(for: slotStyle))
    }

    private var shouldShowCloseButton: Bool {
        assistantSession.isVisible && stateProvider.recordingState == .idle && !assistantSession.isBusy
    }

    private var liveAssistantFollowUpText: String {
        guard showLiveTranscript, stateProvider.recordingState == .recording else { return "" }
        return stateProvider.partialTranscript
    }

    var body: some View {
        let theme = RecorderTheme(rawValue: themeRaw) ?? .dark
        let layoutStyle = RecorderDisplayPlanner.layoutStyle(for: style, assistantVisible: assistantSession.isVisible)
        if layoutStyle == .dot {
            DotRecorderLayout(
                recordingState: stateProvider.recordingState,
                theme: theme,
                placement: MiniRecorderPlacement(rawValue: placementRaw) ?? .bottom,
                levelHistoryProvider: recorder.levelHistorySnapshot,
                clockProvider: recorder.recordingClockSnapshot,
                onRecordButtonTapped: onRecordButtonTapped
            )
        } else {
            MiniRecorderLayout(
                recordingState: stateProvider.recordingState,
                liveContent: LiveTranscriptContent.resolve(
                    enabled: showLiveTranscript,
                    state: stateProvider.recordingState,
                    partial: stateProvider.partialTranscript,
                    expectsPartials: stateProvider.expectsPartialTranscript
                ),
                theme: theme,
                transcriptSize: LiveTranscriptSize(rawValue: liveTranscriptSizeRaw) ?? .medium,
                placement: MiniRecorderPlacement(rawValue: placementRaw) ?? .bottom,
                hasAssistantResponse: assistantSession.isVisible,
                showsCloseButton: shouldShowCloseButton,
                levelHistoryProvider: recorder.levelHistorySnapshot,
                levelDisplay: RecorderLevelDisplay(rawValue: levelDisplayRaw) ?? .bars,
                variant: layoutStyle == .pill ? .pill : .mini,
                slots: RecorderSideSlots(storedValue: slotsRaw, style: style == .dot ? .pill : style),
                modeName: modeManager.currentEffectiveConfiguration?.name ?? String(localized: "None"),
                clockProvider: recorder.recordingClockSnapshot,
                onRecordButtonTapped: onRecordButtonTapped,
                onCloseTapped: onCloseTapped,
                modeButton: RecorderModeButton(buttonSize: 22, padding: EdgeInsets()),
                assistantPanel: AssistantPanelView(
                    session: assistantSession,
                    liveFollowUpText: liveAssistantFollowUpText,
                    onSend: onAssistantFollowUp
                )
            )
        }
    }
}
