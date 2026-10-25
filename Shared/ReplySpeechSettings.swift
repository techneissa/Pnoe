import Foundation

/// The settings behind "Read Replies Aloud": whether Pnoe speaks the Assistant's answer, and the voice for each
/// speech source. Keys, defaults and the fallbacks for a missing or stale value live here so the speaker, the settings
/// screen, the backup and the tests read one source.
enum ReplySpeechSettings {
    /// On: the Assistant's answer is spoken once it appears. Off by default.
    static let enabledKey = "readRepliesAloud"
    /// The voice name sent to Ollama (`default` is the one every speech model has).
    static let ollamaVoiceKey = "readRepliesOllamaVoice"
    /// An Apple voice identifier; empty picks a voice that fits the language of the reply.
    static let appleVoiceKey = "readRepliesAppleVoice"

    static let defaultOllamaVoice = "default"
    static let defaultAppleVoice = ""

    static let ollamaBaseURLKey = "ollamaBaseURL"
    static let defaultOllamaBaseURL = "http://localhost:11434"

    /// What a fresh install gets; the app registers it at launch, so a value the user saved is never replaced.
    static let registeredDefaults: [String: Any] = [
        enabledKey: false,
        ollamaVoiceKey: defaultOllamaVoice,
        appleVoiceKey: defaultAppleVoice,
    ]

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    static func ollamaVoice(defaults: UserDefaults = .standard) -> String {
        let saved = defaults.string(forKey: ollamaVoiceKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? defaultOllamaVoice : saved
    }

    static func appleVoice(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: appleVoiceKey) ?? defaultAppleVoice
    }

    /// The Ollama address Pnoe already uses for AI models; a saved value that is not a URL falls back to the default.
    static func ollamaBaseURL(defaults: UserDefaults = .standard) -> URL {
        let saved = defaults.string(forKey: ollamaBaseURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !saved.isEmpty, let url = URL(string: saved), url.scheme != nil, url.host != nil { return url }
        return URL(string: defaultOllamaBaseURL)!
    }

    /// Writes the values a backup holds. A value the backup lacks (an older file) leaves the current one alone.
    static func apply(
        enabled: Bool?, ollamaVoice: String?, appleVoice: String?, to defaults: UserDefaults = .standard
    ) {
        if let enabled { defaults.set(enabled, forKey: enabledKey) }
        if let ollamaVoice { defaults.set(ollamaVoice, forKey: ollamaVoiceKey) }
        if let appleVoice { defaults.set(appleVoice, forKey: appleVoiceKey) }
    }

    /// The voice to send: the saved one when the model has it, else `default` when it has that, else its first voice.
    /// A voice that was removed from the model must not make every request fail with a 400.
    static func effectiveOllamaVoice(saved: String, available: [String]) -> String {
        if available.isEmpty || available.contains(saved) { return saved }
        if available.contains(defaultOllamaVoice) { return defaultOllamaVoice }
        return available[0]
    }
}
