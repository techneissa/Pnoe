import Foundation

/// Why a take was pasted as raw (code-cleaned) text instead of model output.
/// The raw values are the reason codes that logs and diagnostics carry; they never hold text.
public enum FallbackReason: String, Error, Sendable, CaseIterable, Codable {
    // Not an error: the take was too short to need the model.
    case tooShort = "too_short"
    // Gate and runtime.
    case disabled
    case contextOff = "context_off"
    case modelNotReady = "model_not_ready"
    case modelLoading = "model_loading"
    case timeout
    case runtimeCrashed = "runtime_crashed"
    case runtimeError = "runtime_error"
    case cancelled
    case emptyInput = "empty_input"
    // Sanitizer.
    case truncated
    case wrapper
    case empty
    // Placeholders.
    case placeholderLost = "placeholder_lost"
    case placeholderDup = "placeholder_dup"
    case placeholderOrder = "placeholder_order"
    case placeholderUnknown = "placeholder_unknown"
    // Word-diff guard.
    case length
    case newWords = "new_words"
    case dropped
    case droppedSpan = "dropped_span"
    case newNumber = "new_number"
    case inventedCurrency = "invented_currency"
    case meta
    case questionLost = "question_lost"
    case statementToQuestion = "statement_to_question"

    /// True for reasons that are not a guard or runtime failure, so a fallback-rate count can skip them.
    public var isExpected: Bool {
        switch self {
        case .tooShort, .disabled, .contextOff, .emptyInput: true
        default: false
        }
    }
}
