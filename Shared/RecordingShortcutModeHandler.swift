import Foundation

// How a recording shortcut turns key-down and key-up into starting and stopping the recorder, for
// every mode. The actions are generic and the recorder is closures, so the unit tests compile this
// file directly.

enum RecordingShortcutMode: String, CaseIterable {
    case toggle = "toggle"
    case pushToTalk = "pushToTalk"
    case hybrid = "hybrid"
    case doubleTap = "doubleTap"

    var displayName: String {
        switch self {
        case .toggle: return String(localized: "Toggle")
        case .pushToTalk: return String(localized: "Push to Talk")
        case .hybrid: return String(localized: "Hybrid")
        case .doubleTap: return String(localized: "Double Tap")
        }
    }
}

@MainActor
final class RecordingShortcutModeHandler<Action: Hashable> {
    private let isModeAction: (Action) -> Bool
    private let canHandleShortcutAction: @MainActor () -> Bool
    private let isRecorderPanelVisible: @MainActor () -> Bool
    private let recordingState: @MainActor () -> RecordingState
    private let toggleRecorderPanel: @MainActor (UUID?) async -> Void
    private let cancelRecording: @MainActor () async -> Void

    private var shortcutPressStartTime: TimeInterval?
    private var isHandsFreeRecording = false
    private var isShortcutPressed = false
    private var activeRecordingShortcutAction: Action?
    private var interruptedRecordingActions = Set<Action>()
    private var activeShortcutCanCancelAccidentalStart = false
    private var activeShortcutIsDoubleTap = false
    private var lastShortcutPressTime: Date?
    private var pendingDoubleTapReleaseTimes: [Action: TimeInterval] = [:]

    private let shortcutPressCooldown: TimeInterval = 0.5
    private let hybridPressThreshold: TimeInterval = 0.5
    private let doubleTapThreshold: TimeInterval = 0.7

    init(
        isModeAction: @escaping (Action) -> Bool,
        canHandleShortcutAction: @escaping @MainActor () -> Bool,
        isRecorderVisible: @escaping @MainActor () -> Bool,
        recordingState: @escaping @MainActor () -> RecordingState,
        toggleRecorderPanel: @escaping @MainActor (UUID?) async -> Void,
        cancelRecording: @escaping @MainActor () async -> Void
    ) {
        self.isModeAction = isModeAction
        self.canHandleShortcutAction = canHandleShortcutAction
        self.isRecorderPanelVisible = isRecorderVisible
        self.recordingState = recordingState
        self.toggleRecorderPanel = toggleRecorderPanel
        self.cancelRecording = cancelRecording
    }

    /// The recorder counts as up for a shortcut unless its take is over and only the paste or the
    /// check mark or error symbol is left: a press then starts the next take at once, and a release
    /// stops that one.
    private func isRecorderVisible() -> Bool {
        isRecorderPanelVisible() && !recordingState().startsNextTakeAtOnce
    }

    func reset() {
        isShortcutPressed = false
        shortcutPressStartTime = nil
        isHandsFreeRecording = false
        activeRecordingShortcutAction = nil
        interruptedRecordingActions.removeAll()
        activeShortcutCanCancelAccidentalStart = false
        activeShortcutIsDoubleTap = false
        clearPendingDoubleTaps()
    }

    func clearPendingDoubleTaps() {
        pendingDoubleTapReleaseTimes.removeAll()
    }

    func clearPendingDoubleTap(for action: Action) {
        pendingDoubleTapReleaseTimes.removeValue(forKey: action)
    }

    func clearPendingModeDoubleTaps() {
        pendingDoubleTapReleaseTimes = pendingDoubleTapReleaseTimes.filter { action, _ in !isModeAction(action) }
    }

    func resetShortcutState(for action: Action) {
        pendingDoubleTapReleaseTimes.removeValue(forKey: action)
        guard activeRecordingShortcutAction == action else { return }
        isShortcutPressed = false
        shortcutPressStartTime = nil
        activeRecordingShortcutAction = nil
        activeShortcutCanCancelAccidentalStart = false
        activeShortcutIsDoubleTap = false
    }

    func handleShortcutDown(
        action: Action,
        eventTime: TimeInterval,
        mode: RecordingShortcutMode,
        modeId: UUID? = nil
    ) async {
        if interruptedRecordingActions.remove(action) != nil {
            return
        }

        if mode == .doubleTap && (!canHandleShortcutAction() || recordingState() == .starting) {
            clearPendingDoubleTap(for: action)
            return
        }

        if mode != .doubleTap, let lastTrigger = lastShortcutPressTime,
            Date().timeIntervalSince(lastTrigger) < shortcutPressCooldown
        {
            return
        }

        guard !isShortcutPressed else {
            return
        }
        isShortcutPressed = true
        activeRecordingShortcutAction = action
        activeShortcutIsDoubleTap = mode == .doubleTap
        activeShortcutCanCancelAccidentalStart = mode != .doubleTap && canCurrentShortcutPressCancelAccidentalStart
        if mode != .doubleTap {
            lastShortcutPressTime = Date()
        }
        shortcutPressStartTime = eventTime

        switch mode {
        case .toggle, .hybrid:
            if isHandsFreeRecording {
                isHandsFreeRecording = false
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
                return
            }

            if !isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }

        case .pushToTalk:
            if !isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }

        case .doubleTap:
            break
        }
    }

    func handleShortcutUp(
        action: Action,
        eventTime: TimeInterval,
        mode: RecordingShortcutMode,
        modeId: UUID? = nil
    ) async {
        guard isShortcutPressed, activeRecordingShortcutAction == action else { return }
        isShortcutPressed = false
        activeRecordingShortcutAction = nil
        activeShortcutCanCancelAccidentalStart = false
        activeShortcutIsDoubleTap = false

        switch mode {
        case .toggle:
            isHandsFreeRecording = true

        case .pushToTalk:
            if isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }

        case .hybrid:
            let pressDuration = shortcutPressStartTime.map { eventTime - $0 } ?? 0
            if pressDuration >= hybridPressThreshold && recordingState() == .recording {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            } else {
                isHandsFreeRecording = true
            }

        case .doubleTap:
            guard canHandleShortcutAction(), recordingState() != .starting else {
                clearPendingDoubleTap(for: action)
                break
            }
            let pressDuration = shortcutPressStartTime.map { eventTime - $0 } ?? 0
            if pressDuration < 0 || pressDuration > doubleTapThreshold {
                pendingDoubleTapReleaseTimes.removeValue(forKey: action)
            } else if let firstRelease = pendingDoubleTapReleaseTimes.removeValue(forKey: action),
                eventTime - firstRelease >= 0,
                eventTime - firstRelease <= doubleTapThreshold
            {
                await toggleRecorderPanel(modeId)
                isHandsFreeRecording = isRecorderVisible()
            } else {
                pendingDoubleTapReleaseTimes[action] = eventTime
            }
        }

        shortcutPressStartTime = nil
    }

    func handleInterruption(action: Action) async {
        guard isShortcutPressed, activeRecordingShortcutAction == action else {
            if canCurrentShortcutPressCancelAccidentalStart {
                interruptedRecordingActions.insert(action)
            }
            return
        }

        if activeShortcutIsDoubleTap {
            isShortcutPressed = false
            shortcutPressStartTime = nil
            activeRecordingShortcutAction = nil
            activeShortcutCanCancelAccidentalStart = false
            activeShortcutIsDoubleTap = false
            pendingDoubleTapReleaseTimes.removeValue(forKey: action)
            return
        }

        guard activeShortcutCanCancelAccidentalStart else { return }

        reset()
        await cancelRecording()
    }

    private var canCurrentShortcutPressCancelAccidentalStart: Bool {
        !isRecorderVisible() && (recordingState() == .idle || recordingState().startsNextTakeAtOnce)
    }
}
