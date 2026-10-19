import SwiftUI

// The two recorder layouts, free of engine, recorder and assistant types: the app's recorder
// views feed them state and hand in the mode button and assistant panel, and the unit tests
// render them offscreen with sample values.

/// Mini and Pill share one layout: a bar with the record button and the side slots that grows
/// into the live transcript line and the assistant panel. The Pill is the compact variant: a
/// capsule with no mode button.
enum MiniRecorderVariant {
    case mini
    case pill
}

struct MiniRecorderLayout<ModeButton: View, AssistantPanel: View>: View {
    let recordingState: RecordingState
    let liveContent: LiveTranscriptContent?
    let theme: RecorderTheme
    let transcriptSize: LiveTranscriptSize
    let placement: MiniRecorderPlacement
    let hasAssistantResponse: Bool
    let showsCloseButton: Bool
    let levelHistoryProvider: () -> LevelHistory
    let levelDisplay: RecorderLevelDisplay
    var variant: MiniRecorderVariant = .mini
    var slots = RecorderSideSlots.defaults(for: .mini)
    var modeName = ""
    var clockProvider: () -> RecordingClock = { RecordingClock() }
    /// Set by the settings preview: no window drag, since the preview sits in the settings window.
    var isPreview = false
    let onRecordButtonTapped: () -> Void
    let onCloseTapped: () -> Void
    let modeButton: ModeButton
    let assistantPanel: AssistantPanel

    // MARK: - Layout Constants

    private let transcriptHorizontalPadding: CGFloat = 16
    private let assistantWidth: CGFloat = 520
    private let expandedCornerRadius: CGFloat = 14

    private var palette: RecorderPalette { theme.palette }
    private var isAtTop: Bool { placement == .top }
    private var hasLiveTranscript: Bool { liveContent != nil }
    private var isPill: Bool { variant == .pill }

    private var controlBarHeight: CGFloat { isPill ? RecorderBarMetrics.pillHeight : 40 }
    private var compactCornerRadius: CGFloat { isPill ? RecorderBarMetrics.pillHeight / 2 : 20 }

    private var compactWidth: CGFloat {
        isPill
            ? RecorderBarMetrics.pillBarWidth(slots: slots) : RecorderBarMetrics.miniBarWidth(slots: slots)
    }

    private var expandedWidth: CGFloat {
        isPill
            ? max(RecorderBarMetrics.miniExpandedWidth, RecorderBarMetrics.pillBarWidth(slots: slots))
            : RecorderBarMetrics.miniExpandedBarWidth(slots: slots)
    }

    private func slotView(_ side: RecorderSlotSide) -> some View {
        RecorderSlotView(
            content: slots.content(on: side),
            recordingState: recordingState,
            levelHistoryProvider: levelHistoryProvider,
            levelDisplay: levelDisplay,
            clockProvider: clockProvider,
            modeName: modeName
        )
    }

    /// The slots side by side. An empty slot takes no room, so a single slot sits in the middle.
    @ViewBuilder
    private var slotsView: some View {
        if slots.contentWidth > 0 {
            HStack(spacing: RecorderBarMetrics.slotSpacing) {
                if slots.left != .none { slotView(.left) }
                if slots.right != .none { slotView(.right) }
            }
        }
    }

    private var recordOrCloseButton: some View {
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
    }

    @ViewBuilder
    private var controlBar: some View {
        if isPill {
            HStack(spacing: 10) {
                recordOrCloseButton
                Spacer(minLength: 0)
                slotsView
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(height: controlBarHeight)
        } else {
            HStack(spacing: 0) {
                recordOrCloseButton
                    .padding(.leading, 10)

                Spacer(minLength: 0)

                slotsView

                Spacer(minLength: 0)

                modeButton
                    .padding(.trailing, 12)
            }
            .frame(height: controlBarHeight)
        }
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
        .gesture(WindowDragGesture(), isEnabled: !isPreview)
        .allowsWindowActivationEvents(!isPreview)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isAtTop ? .top : .bottom)
    }
}

/// The dot style: a small capsule with the dot and, while recording, the time. No live line and
/// no assistant panel; while the assistant is open the pill layout is shown instead.
struct DotRecorderLayout: View {
    let recordingState: RecordingState
    let theme: RecorderTheme
    let placement: MiniRecorderPlacement
    let levelHistoryProvider: () -> LevelHistory
    var clockProvider: () -> RecordingClock = { RecordingClock() }
    var isPreview = false
    let onRecordButtonTapped: () -> Void

    var body: some View {
        Button(action: onRecordButtonTapped) {
            RecorderDotView(
                recordingState: recordingState,
                levelHistoryProvider: levelHistoryProvider,
                clockProvider: clockProvider)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!recordingState.allowsRecordButton)
        .help(recordingState.recordButtonLabel)
        .accessibilityLabel(Text(recordingState.recordButtonLabel))
        .recorderThemed(theme, shape: Capsule())
        .animation(.easeInOut(duration: 0.2), value: RecorderDotView.showsTimer(for: recordingState))
        .gesture(WindowDragGesture(), isEnabled: !isPreview)
        .allowsWindowActivationEvents(!isPreview)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: placement == .top ? .top : .bottom)
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
    let levelHistoryProvider: () -> LevelHistory
    let levelDisplay: RecorderLevelDisplay
    var slots = RecorderSideSlots.defaults(for: .notch)
    var modeName = ""
    var clockProvider: () -> RecordingClock = { RecordingClock() }
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

    // How far the pill reaches out on each side. The base is what each state always had; a slot
    // that needs more room (the timer or the mode name next to the buttons) widens it.
    private var recordingSideExpansion: CGFloat {
        RecorderBarMetrics.notchSideExpansion(base: 90, edgePadding: 16, slots: slots)
    }
    private var transcriptSideExpansion: CGFloat {
        RecorderBarMetrics.notchSideExpansion(base: 110, edgePadding: 20, slots: slots)
    }
    private var assistantSideExpansion: CGFloat {
        RecorderBarMetrics.notchSideExpansion(base: 230, edgePadding: 20, slots: slots)
    }
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

    private func slotView(_ side: RecorderSlotSide) -> some View {
        RecorderSlotView(
            content: slots.content(on: side),
            recordingState: recordingState,
            levelHistoryProvider: levelHistoryProvider,
            levelDisplay: levelDisplay,
            clockProvider: clockProvider,
            modeName: modeName,
            menuBarHeight: notchHeight
        )
    }

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
                if slots.left != .none { slotView(.left) }
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
                if slots.right != .none { slotView(.right) }
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
