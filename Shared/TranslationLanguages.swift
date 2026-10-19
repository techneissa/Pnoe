import Foundation

/// The languages the Translation workflow can write. The name goes into the prompt as is, so it stays
/// English; the picker shows the name in the user's language.
enum TranslationLanguages {
    static let defaultName = "English"

    static let names = [
        "English", "Spanish", "French", "German", "Italian", "Portuguese", "Dutch", "Swedish", "Polish", "Turkish",
        "Russian", "Ukrainian", "Arabic", "Hindi", "Chinese (Simplified)", "Chinese (Traditional)", "Japanese",
        "Korean", "Vietnamese", "Indonesian",
    ]

    static func displayName(for name: String) -> String {
        Locale.current.localizedString(forIdentifier: identifiers[name] ?? "") ?? name
    }

    private static let identifiers = [
        "English": "en", "Spanish": "es", "French": "fr", "German": "de", "Italian": "it", "Portuguese": "pt",
        "Dutch": "nl", "Swedish": "sv", "Polish": "pl", "Turkish": "tr", "Russian": "ru", "Ukrainian": "uk",
        "Arabic": "ar", "Hindi": "hi", "Chinese (Simplified)": "zh-Hans", "Chinese (Traditional)": "zh-Hant",
        "Japanese": "ja", "Korean": "ko", "Vietnamese": "vi", "Indonesian": "id",
    ]
}
