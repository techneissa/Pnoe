import Foundation

/// Which installed Ollama model the app preselects for a new AI workflow, so it runs on this Mac with no
/// setup. Only models that are already pulled are considered; nothing is downloaded or started.
public enum LocalModelPreselection {
    /// Model families that follow instructions well at small sizes.
    static let families = ["gemma", "qwen"]

    /// Tag words that mark a model that does not chat or does not suit plain text jobs: base and
    /// pre-trained weights, code and vision variants, math models.
    static let excludedTagWords: Set<String> = ["base", "text", "pt", "coder", "code", "vl", "vision", "math", "guard"]

    /// Under this size a model is too small to rewrite text reliably.
    static let minimumSizeBytes: Int64 = 900_000_000

    /// The smallest suitable Gemma or Qwen instruct model in `entries`, or nil when none qualifies (Ollama
    /// not running, no such model pulled). Ties go to the name that sorts first.
    public static func choose(from entries: [FormatterModelEntry]) -> FormatterModelEntry? {
        entries
            .filter(isSuitable)
            .min { lhs, rhs in
                let left = lhs.sizeBytes ?? .max
                let right = rhs.sizeBytes ?? .max
                if left != right { return left < right }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }

    /// Asks `discovery` for the installed models and chooses. The app passes `OllamaModelDiscovery.fetch`;
    /// a test passes a fake.
    public static func choose(discovery: @Sendable () async -> [FormatterModelEntry]) async -> FormatterModelEntry? {
        choose(from: await discovery())
    }

    static func isSuitable(_ entry: FormatterModelEntry) -> Bool {
        guard entry.kind == .ollama, entry.source == .ollama else { return false }
        let name = entry.displayName.lowercased()
        guard families.contains(where: name.contains) else { return false }
        // "qwen2.5vl:3b" splits into qwen2, 5vl and 3b; dropping leading digits leaves the vl.
        let words = Set(
            name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map { String($0.drop(while: \.isNumber)) })
        guard words.isDisjoint(with: excludedTagWords) else { return false }
        if let size = entry.sizeBytes, size < minimumSizeBytes { return false }
        return true
    }
}
