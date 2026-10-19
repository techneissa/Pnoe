import Foundation

/// Word lists shared by the guards. Kept in one file so a tuning pass touches one place.
enum WordLists {
    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "hmm", "hm", "mm", "mmm"]

    static let fileExtensions: Set<String> = [
        "py", "ts", "tsx", "js", "jsx", "mjs", "swift", "yaml", "yml", "json", "md", "txt", "sh", "zsh", "plist",
        "rs", "go", "rb", "java", "kt", "c", "h", "cpp", "hpp", "m", "cs", "php", "html", "css", "scss",
        "toml", "ini", "cfg", "conf", "xml", "csv", "sql", "lock", "log", "gradle", "xcconfig", "pbxproj",
        "storyboard", "xib", "pdf", "png", "jpg", "jpeg", "gif", "svg", "zip", "gz", "tar", "dmg",
    ]

    static let topLevelDomains: Set<String> = [
        "com", "org", "net", "io", "dev", "app", "ai", "co", "edu", "gov", "us", "uk", "de", "fr", "me", "info",
        "biz", "xyz", "tv", "ca", "au", "nl", "se", "ch",
    ]

    /// Words that cannot be a path segment or file name, so "and slash or" never becomes `and/or`.
    static let functionWords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "to", "in", "on", "at", "is", "it", "for", "with", "as", "but",
        "if", "so", "i", "you", "we", "they", "he", "she", "that", "this", "my", "your",
    ]

    static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "to", "of", "in", "on", "at", "is", "are", "was", "were", "be",
        "been", "it", "its", "that", "this", "these", "those", "i", "you", "we", "he", "she", "they", "me", "us",
        "him", "her", "them", "my", "your", "our", "his", "their", "for", "with", "as", "by", "from", "so",
        "if", "then", "than", "do", "does", "did", "will", "would", "can", "could", "should", "have", "has",
        "had", "am", "just", "also", "very", "really", "there", "here", "what", "when", "where", "which",
        "who", "how", "why", "up", "out", "about", "into", "over", "some", "any", "all", "one",
    ]

    /// Spoken command words code and model may drop (the model turns them into symbols).
    static let commandWords: Set<String> = ["comma", "period", "colon", "semicolon", "bullet", "bullets", "parenthesis", "paren"]
    static let commandPhrases: [[String]] = [
        ["new", "line"], ["new", "paragraph"], ["question", "mark"], ["exclamation", "mark"], ["exclamation", "point"],
        ["full", "stop"], ["open", "parenthesis"], ["close", "parenthesis"], ["open", "paren"], ["close", "paren"],
    ]
    static let fillerPhrases: [[String]] = [["you", "know"]]
    static let fillerWords: Set<String> = fillers.union(["like"])
    /// May be dropped at the very start of a take.
    static let leadingMarkers: Set<String> = ["so", "okay", "ok", "well", "yeah", "hey"]

    static let correctionPhrases: [[String]] = [
        ["no", "wait"], ["no", "actually"], ["wait", "no"], ["actually", "no"], ["i", "mean"], ["sorry"],
        ["scratch", "that"],
    ]

    static let interrogatives: Set<String> = ["what", "why", "how", "who", "when", "where", "which", "whose"]
    static let questionAuxiliaries: Set<String> = [
        "can", "could", "would", "will", "should", "do", "does", "did", "is", "are", "was", "were", "am", "have", "has",
    ]
    static let questionSecondWords: Set<String> = [
        "you", "we", "i", "they", "he", "she", "it", "there", "this", "that", "the", "anyone", "someone", "everyone", "a",
    ]
    static let leadingInterjections: Set<String> = ["hey", "okay", "ok", "so", "well", "yeah", "hi", "um", "uh", "and", "but"]

    static let metaPhrases: [[String]] = [
        ["here", "is"], ["here's"], ["here", "are"], ["sure"], ["certainly"], ["of", "course"], ["i'm", "sorry"],
        ["i", "am", "sorry"], ["sorry", "but"], ["as", "an", "ai"], ["i", "cannot"], ["i", "can't"], ["i", "can", "not"],
        ["i", "apologize"], ["hope", "this", "helps"], ["cleaned", "transcript"], ["cleaned", "text"], ["i'd", "be", "happy", "to"],
    ]
}
