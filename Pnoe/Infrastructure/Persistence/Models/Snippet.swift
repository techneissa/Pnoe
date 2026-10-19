import Foundation
import SwiftData

/// A spoken trigger phrase and the text it inserts. Lives in the dictionary store next to word replacements.
@Model
final class Snippet {
    var id: UUID = UUID()
    var trigger: String = ""
    var expansion: String = ""
    var dateAdded: Date = Date()

    init(trigger: String, expansion: String, dateAdded: Date = Date()) {
        self.trigger = SnippetTrigger.normalized(trigger)
        self.expansion = Snippet.cleanedExpansion(expansion)
        self.dateAdded = dateAdded
    }

    /// The expansion keeps its line breaks and inner spacing; only the edges are trimmed.
    static func cleanedExpansion(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }
}
