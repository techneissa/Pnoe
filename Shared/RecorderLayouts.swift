import SwiftUI

// The two recorder layouts, free of engine, recorder and assistant types: the app's recorder
// views feed them state and hand in the mode button and assistant panel, and the unit tests
// render them offscreen with sample values.

struct MiniRecorderLayout<ModeButton: View, AssistantPanel: View>: View {
    let recordingState: RecordingState
    let liveContent: LiveTranscriptContent?
    let theme: RecorderTheme
    let transcriptSize: LiveTranscriptSize
    let placement: MiniRecorderPlacement
    let hasAssistantResponse: Bool
    let showsCloseButton: Bool
    let audioMeterProvider: () -> AudioMeter
    let onRecordButtonTapped: () -> Void
    let onCloseTapped: () -> Void
    let modeButton: ModeButton
    let assistantPanel: AssistantPanel

    // MARK: - Layout Constants

    private let controlBarHeight: CGFloat = 40
    private let compactWidth: CGFloat = 184
    private let expandedWidth: CGFloat = 300
    private let transcriptHorizontalPadding: CGFloat = 16
    private let assistantWidth: CGFloat = 520
    private let compactCornerRadius: CGFloat = 20
    private let expandedCornerRadius: CGFloat = 14

    private var palette: RecorderPalette { theme.palette }
    private var isAtTop: Bool { placement == .top }
    private var hasLiveTranscript: Bool { liveContent != nil }

    private var controlBar: some View {
        HStack(spacing: 0) {
            Group {
                if showsCloseButton {
                    RecorderCloseButton(action: onCloseTapped)
                } else {
                    RecorderRecordButton(
                        recordingState: recordingState,
                        action: onRecordButtonTapped
                    )
                }
            }
            .padding(.leading, 10)

            Spacer(minLength: 0)

            RecorderStatusDisplay(
                currentState: recordingState,
                audioMeterProvider: audioMeterProvider
            )

            Spacer(minLength: 0)

            modeButton
                .padding(.trailing, 12)
        }
        .frame(height: controlBarHeight)
    }

    /// The live line sits on the side of the bar that faces into the screen: under the bar at
    /// the top, above it at the bottom, so the bar itself never moves while words arrive.
    @ViewBuilder
    private var transcriptSection: some View {
        if let liveContent {
            VStack(spacing: 0) {
                if isAtTop { Divider().background(palette.ink.opacity(0.15)) }
                LiveTranscriptView(
                    content: liveContent,
                    size: transcriptSize,
                    textWidth: expandedWidth - transcriptHorizontalPadding * 2
                )
                if !isAtTop { Divider().background(palette.ink.opacity(0.15)) }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasAssistantResponse {
                if isAtTop {
                    controlBar
                    Divider().background(palette.ink.opacity(0.15))
                    assistantPanel
                } else {
                    assistantPanel
                    Divider().background(palette.ink.opacity(0.15))
                    controlBar
                }
            } else if isAtTop {
                controlBar
                transcriptSection
            } else {
                transcriptSection
                controlBar
            }
        }
        .frame(width: hasAssistantResponse ? assistantWidth : (hasLiveTranscript ? expandedWidth : compactWidth))
        .recorderThemed(
            theme,
            shape: RoundedRectangle(
                cornerRadius: hasLiveTranscript || hasAssistantResponse ? expandedCornerRadius : compactCornerRadius,
                style: .continuous)
        )
        .animation(.easeInOut(duration: 0.3), value: hasLiveTranscript)
        .animation(.easeInOut(duration: 0.3), value: hasAssistantResponse)
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isAtTop ? .top : .bottom)
    }
}

struct NotchRecorderLayout<ModeButton: View, AssistantPanel: View>: View {
    let recordingState: RecordingState
    let liveContent: LiveTranscriptContent?
    let theme: RecorderTheme
    let transcriptSize: LiveTranscriptSize
    let isAlwaysVisible: Bool
    let hasAssistantResponse: Bool
    let showsCloseButton: Bool
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let audioMeterProvider: () -> AudioMeter
    let onRecordButtonTapped: () -> Void
    let onCloseTapped: () -> Void
    let modeButton: ModeButton
    let assistantPanel: AssistantPanel

    // MARK: - Display State

    private enum DisplayState: Equatable {
        case collapsed
        case active
        case liveText
        case assistant
    }

    private var displayState: DisplayState {
        if hasAssistantResponse {
            return .assistant
        }

        switch recordingState {
        case .recording:
            return liveContent != nil ? .liveText : .active
        case .transcribing, .enhancing:
            return .active
        default:
            // With the visibility setting "Always" the idle indicator keeps the recording layout.
            return isAlwaysVisible ? .active : .collapsed
        }
    }

    // MARK: - Layout Constants

    private let recordingSideExpansion: CGFloat = 90
    private let transcriptSideExpansion: CGFloat = 110
    private let assistantSideExpansion: CGFloat = 230
    private let activeHeightBonus: CGFloat = 6
    private let assistantPanelHeight: CGFloat = 320

    private var transcriptPanelHeight: CGFloat {
        LiveTranscriptMetrics.height(for: transcriptSize) + 1
    }

    private var mainRowHeight: CGFloat { notchHeight + activeHeightBonus }

    private var palette: RecorderPalette { theme.palette }

    // MARK: - Pill Dimensions

    private var pillWidth: CGFloat {
        switch displayState {
        case .collapsed: return notchWidth
        case .active: return notchWidth + recordingSideExpansion * 2
        case .liveText: return notchWidth + transcriptSideExpansion * 2
        case .assistant: return notchWidth + assistantSideExpansion * 2
        }
    }

    private var pillHeight: CGFloat {
        switch displayState {
        case .collapsed: return 0
        case .active: return mainRowHeight
        case .liveText: return mainRowHeight + transcriptPanelHeight
        case .assistant: return mainRowHeight + assistantPanelHeight
        }
    }

    private var sideExpansion: CGFloat {
        switch displayState {
        case .liveText:
            return transcriptSideExpansion
        case .assistant:
            return assistantSideExpansion
        case .active, .collapsed:
            return recordingSideExpansion
        }
    }

    private var sideEdgePadding: CGFloat {
        displayState == .liveText || displayState == .assistant ? 20 : 16
    }

    // MARK: - Animation

    private let expandAnimation = Animation.spring(response: 0.42, dampingFraction: 0.80)
    private let collapseAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0)

    private var pillAnimation: Animation {
        displayState == .collapsed ? collapseAnimation : expandAnimation
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            pill.position(x: geo.size.width / 2, y: pillHeight / 2)
        }
        .animation(pillAnimation, value: displayState)
    }

    // MARK: - Pill

    private var pill: some View {
        VStack(spacing: 0) {
            mainRow
            liveTextPanel
            assistantSection
        }
        .frame(width: pillWidth, height: pillHeight)
        .recorderThemed(
            theme,
            shape: NotchShape(
                topCornerRadius: displayState == .liveText ? 12 : 8,
                bottomCornerRadius: displayState == .liveText || displayState == .assistant ? 22 : 16
            )
        )
    }

    // MARK: - Main Row

    private var mainRow: some View {
        ZStack {
            Color.clear

            HStack(spacing: 14) {
                if showsCloseButton {
                    RecorderCloseButton(action: onCloseTapped)
                } else {
                    RecorderRecordButton(
                        recordingState: recordingState,
                        action: onRecordButtonTapped
                    )
                }
                modeButton
                Spacer(minLength: 0)
            }
            .padding(.leading, sideEdgePadding)
            .frame(width: sideExpansion)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(displayState != .collapsed ? 1 : 0)
            .animation(
                displayState != .collapsed ? expandAnimation.delay(0.09) : collapseAnimation,
                value: displayState
            )

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                RecorderStatusDisplay(
                    currentState: recordingState,
                    audioMeterProvider: audioMeterProvider,
                    menuBarHeight: notchHeight
                )
            }
            .padding(.trailing, sideEdgePadding)
            .frame(width: sideExpansion)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(displayState != .collapsed ? 1 : 0)
            .animation(
                displayState != .collapsed ? expandAnimation.delay(0.09) : collapseAnimation,
                value: displayState
            )
        }
        .frame(height: mainRowHeight)
    }

    // MARK: - Live Text Panel

    private var liveTextPanel: some View {
        VStack(spacing: 0) {
            if displayState == .liveText, let liveContent {
                Divider().background(palette.ink.opacity(0.15))
                LiveTranscriptView(
                    content: liveContent,
                    size: transcriptSize,
                    textWidth: pillWidth - 48
                )
            }
        }
        .frame(height: displayState == .liveText ? transcriptPanelHeight : 0)
        .clipped()
    }

    private var assistantSection: some View {
        VStack(spacing: 0) {
            if displayState == .assistant {
                Divider().background(palette.ink.opacity(0.15))
                assistantPanel
            }
        }
        .frame(height: displayState == .assistant ? assistantPanelHeight : 0)
        .clipped()
    }
}
