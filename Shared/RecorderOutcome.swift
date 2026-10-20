import Foundation

// How a take ends in the recorder: a check mark when its text was pasted, the error symbol when it
// was cancelled or failed, each shown for `Motion.outcomeHold` and then hidden. Plain values and
// closures with no dependency on the rest of the app, so the unit tests compile this file directly.

enum RecorderOutcome: Equatable {
    case done
    case failed

    /// The recorder state that shows this outcome.
    var state: RecordingState {
        switch self {
        case .done: return .done
        case .failed: return .failed
        }
    }

    /// The phase the symbol effects follow: a check mark bounces once, the error symbol wiggles once.
    var phase: MotionPhase {
        switch self {
        case .done: return .finished
        case .failed: return .failed
        }
    }
}

extension RecordingState {
    /// A take is being transcribed or enhanced: the recorder shows its processing indicator.
    var isProcessing: Bool { self == .transcribing || self == .enhancing || self == .pasting }

    /// The recorder shows the check mark or the error symbol.
    var isOutcome: Bool { self == .done || self == .failed }

    /// The take is over for the user (its text is being pasted, or its outcome shows): a shortcut
    /// press starts the next take at once instead of waiting.
    var startsNextTakeAtOnce: Bool { self == .pasting || isOutcome }

    /// Whether a recording shortcut is handled in this state. Not while a take is being transcribed or
    /// enhanced; while it pastes, shows an outcome or has nothing running, a press starts a take.
    var acceptsShortcutAction: Bool { self != .transcribing && self != .enhancing && self != .busy }

    /// The outcome this state shows, if it is one.
    var outcome: RecorderOutcome? {
        switch self {
        case .done: return .done
        case .failed: return .failed
        default: return nil
        }
    }
}

/// Moves a take from its last state to an outcome, holds it, then hides the recorder. It never
/// delays anything: `show` sets the state at once, and a new recording (`interrupt`) replaces the
/// outcome at once and cancels the pending hide, so a late timer can never hide a newer take.
@MainActor
final class RecorderOutcomeFlow {
    private let currentState: () -> RecordingState
    private let setState: (RecordingState) -> Void
    private let isRecorderVisible: () -> Bool
    private let hide: () async -> Void
    private let hold: TimeInterval
    private var pendingHide: Task<Void, Never>?
    private var generation = 0

    init(
        hold: TimeInterval = Motion.outcomeHold,
        currentState: @escaping () -> RecordingState,
        setState: @escaping (RecordingState) -> Void,
        isRecorderVisible: @escaping () -> Bool,
        hide: @escaping () async -> Void
    ) {
        self.hold = hold
        self.currentState = currentState
        self.setState = setState
        self.isRecorderVisible = isRecorderVisible
        self.hide = hide
    }

    /// An outcome may replace a take that is still processing, or one that was just cancelled or
    /// ended before it recorded (idle). Never a recording that has started, another outcome, or a
    /// recorder that is already hidden.
    static func canShow(over state: RecordingState, recorderVisible: Bool) -> Bool {
        recorderVisible && (state.isProcessing || state == .idle)
    }

    /// Shows `outcome` and schedules the hide (`hidesRecorder: false` for a recorder that must stay
    /// up, such as one carrying an assistant answer). Returns false, changing nothing, when the take's
    /// recorder is already hidden or replaced, so the caller can fall back to hiding it.
    @discardableResult
    func show(_ outcome: RecorderOutcome, hidesRecorder: Bool = true) -> Bool {
        guard Self.canShow(over: currentState(), recorderVisible: isRecorderVisible()) else { return false }
        pendingHide?.cancel()
        generation += 1
        let mine = generation
        setState(outcome.state)
        pendingHide = Task { [weak self, hold] in
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            guard !Task.isCancelled, let self, self.generation == mine,
                self.currentState() == outcome.state
            else { return }
            self.pendingHide = nil
            self.setState(.idle)
            if hidesRecorder { await self.hide() }
        }
        return true
    }

    /// A new recording starts, or the recorder is closed: drop the outcome and its pending hide.
    func interrupt() {
        pendingHide?.cancel()
        pendingHide = nil
        generation += 1
        if currentState().isOutcome { setState(.idle) }
    }

    /// How long the recorder waits for a paste result before it shows the error.
    static let pasteTimeout: TimeInterval = 3

    /// Starts the paste first, waits until it has landed, and only then reports `.done` (or
    /// `.failed` when it did not land or the take had an error on the way). Returns the paste's
    /// own result for the caller's follow-up. The report never starts or delays the paste.
    /// When no result has come back after `timeout`, reports `.failed` (as far as Pnoe knows the paste
    /// did not land), returns nil, and ignores a result that arrives later.
    static func report<Result>(
        afterPaste startPaste: () -> Task<Result, Never>,
        landed: @escaping (Result) -> Bool,
        takeHadError: Bool = false,
        timeout: TimeInterval = RecorderOutcomeFlow.pasteTimeout,
        into reporter: @escaping (RecorderOutcome) -> Void
    ) async -> Result? {
        let paste = startPaste()
        var finished = false
        return await withCheckedContinuation { (continuation: CheckedContinuation<Result?, Never>) in
            Task { @MainActor in
                let result = await paste.value
                guard !finished else { return }
                finished = true
                reporter(landed(result) && !takeHadError ? .done : .failed)
                continuation.resume(returning: result)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !finished else { return }
                finished = true
                reporter(.failed)
                continuation.resume(returning: nil)
            }
        }
    }
}
