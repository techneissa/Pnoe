import SwiftUI

struct MiniRecorderView<S: RecorderStateProvider & ObservableObject>: View {
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

    private var shouldShowCloseButton: Bool {
        assistantSession.isVisible && stateProvider.recordingState == .idle && !assistantSession.isBusy
    }

    private var liveAssistantFollowUpText: String {
        guard showLiveTranscript, stateProvider.recordingState == .recording else { return "" }
        return stateProvider.partialTranscript
    }

    var body: some View {
        MiniRecorderLayout(
            recordingState: stateProvider.recordingState,
            liveContent: LiveTranscriptContent.resolve(
                enabled: showLiveTranscript,
                state: stateProvider.recordingState,
                partial: stateProvider.partialTranscript,
                expectsPartials: stateProvider.expectsPartialTranscript
            ),
            theme: RecorderTheme(rawValue: themeRaw) ?? .dark,
            transcriptSize: LiveTranscriptSize(rawValue: liveTranscriptSizeRaw) ?? .medium,
            placement: MiniRecorderPlacement(rawValue: placementRaw) ?? .bottom,
            hasAssistantResponse: assistantSession.isVisible,
            showsCloseButton: shouldShowCloseButton,
            levelHistoryProvider: recorder.levelHistorySnapshot,
            levelDisplay: RecorderLevelDisplay(rawValue: levelDisplayRaw) ?? .bars,
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
