import SwiftUI

struct NotchRecorderView<S: RecorderStateProvider & ObservableObject>: View {
    @ObservedObject var stateProvider: S
    @ObservedObject var recorder: Recorder
    @ObservedObject var assistantSession: AssistantSession
    let onRecordButtonTapped: () -> Void
    let onCloseTapped: () -> Void
    let onAssistantFollowUp: (String) -> Void
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = true
    @AppStorage(RecorderDisplaySettingsKeys.liveTranscriptSize) private var liveTranscriptSizeRaw = LiveTranscriptSize.medium.rawValue
    @AppStorage(RecorderDisplaySettingsKeys.theme) private var themeRaw = RecorderTheme.dark.rawValue
    @AppStorage(RecorderDisplaySettingsKeys.visibility) private var visibilityRaw = RecorderVisibility.whileRecording.rawValue
    /// Bumped on every screen reconfiguration to invalidate the view. The notch metrics below
    /// come from AppKit, which SwiftUI cannot observe on its own, so without this the view keeps
    /// whatever sizes it happened to compute the last time it was rendered.
    @State private var screenGeneration = 0

    /// Reads `screenGeneration` so SwiftUI records a dependency on it: the metrics below come
    /// from AppKit, which it cannot observe, and a view only re-evaluates the parts that depend
    /// on the state that changed.
    private var screenMetrics: (width: CGFloat, height: CGFloat) {
        _ = screenGeneration

        guard let screen = RecorderScreenResolver.resolve() else { return (180, 37) }

        let width: CGFloat = {
            if let left = screen.auxiliaryTopLeftArea?.width,
                let right = screen.auxiliaryTopRightArea?.width
            {
                return screen.frame.width - left - right
            }
            return 180
        }()

        let height: CGFloat = {
            if screen.safeAreaInsets.top > 0 { return screen.safeAreaInsets.top }
            return NSApplication.shared.mainMenu?.menuBarHeight ?? NSStatusBar.system.thickness
        }()

        return (width, height)
    }

    private var shouldShowCloseButton: Bool {
        assistantSession.isVisible && stateProvider.recordingState == .idle && !assistantSession.isBusy
    }

    private var liveAssistantFollowUpText: String {
        guard showLiveTranscript, stateProvider.recordingState == .recording else { return "" }
        return stateProvider.partialTranscript
    }

    var body: some View {
        NotchRecorderLayout(
            recordingState: stateProvider.recordingState,
            liveContent: LiveTranscriptContent.resolve(
                enabled: showLiveTranscript,
                state: stateProvider.recordingState,
                partial: stateProvider.partialTranscript,
                expectsPartials: stateProvider.expectsPartialTranscript
            ),
            theme: RecorderTheme(rawValue: themeRaw) ?? .dark,
            transcriptSize: LiveTranscriptSize(rawValue: liveTranscriptSizeRaw) ?? .medium,
            isAlwaysVisible: RecorderVisibility(rawValue: visibilityRaw) == .always,
            hasAssistantResponse: assistantSession.isVisible,
            showsCloseButton: shouldShowCloseButton,
            notchWidth: screenMetrics.width,
            notchHeight: screenMetrics.height,
            audioMeterProvider: recorder.audioMeterSnapshot,
            onRecordButtonTapped: onRecordButtonTapped,
            onCloseTapped: onCloseTapped,
            modeButton: RecorderModeButton(buttonSize: 20, padding: EdgeInsets()),
            assistantPanel: AssistantPanelView(
                session: assistantSession,
                liveFollowUpText: liveAssistantFollowUpText,
                onSend: onAssistantFollowUp
            )
        )
        .onReceive(
            LifecycleObserver.shared.publisher(for: .screenConfigurationChanged)
        ) { _ in
            screenGeneration += 1
        }
    }
}
