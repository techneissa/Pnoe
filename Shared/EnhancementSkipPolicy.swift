import Foundation

/// When a take goes to the model and when it is pasted as transcribed. One rule for dictation and for the
/// Workflows Playground, so the Playground shows what dictation would paste.
enum EnhancementSkipPolicy {
    static let defaultShortWordThreshold = 3

    /// The saved "short take" word limit, or the default when none is saved.
    static func threshold(saved: Int) -> Int {
        saved > 0 ? saved : defaultShortWordThreshold
    }

    /// A take that is only snippet triggers has nothing left to improve, and a short take is skipped when the
    /// setting is on. A response shown in the recorder always runs the model.
    static func shouldSkip(
        snippetsOnly: Bool, respondInRecorder: Bool, skipShortEnabled: Bool, wordCount: Int, threshold: Int
    ) -> Bool {
        !respondInRecorder && (snippetsOnly || (skipShortEnabled && wordCount <= threshold))
    }
}
