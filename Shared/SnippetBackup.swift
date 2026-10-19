import Foundation

/// A snippet as it is written to a settings backup.
struct SnippetBackup: Codable, Equatable, Sendable {
    let trigger: String
    let expansion: String
}

/// The snippet part of a settings backup, read from and written to the same top-level object as the
/// rest of the file. Backups made before snippets existed have neither key and decode to an empty
/// payload, so they still import.
struct SnippetBackupPayload: Codable, Equatable, Sendable {
    /// Format of the backup file. Files without the key are format 1; snippets arrived in format 2.
    static let currentFormatVersion = 2

    var formatVersion: Int?
    var snippets: [SnippetBackup]?

    init(formatVersion: Int? = nil, snippets: [SnippetBackup]? = nil) {
        self.formatVersion = formatVersion
        self.snippets = snippets
    }

    /// Payload for an export: always stamped with the current format, and `snippets` only when there are some.
    static func forExport(snippets: [SnippetBackup]) -> SnippetBackupPayload {
        SnippetBackupPayload(formatVersion: currentFormatVersion, snippets: snippets.isEmpty ? nil : snippets)
    }

    /// Snippets to add on import: skips unusable rows, duplicates within the file and triggers already saved.
    static func snippetsToImport(_ imported: [SnippetBackup]?, existingTriggers: [String]) -> [SnippetBackup] {
        var taken = Set(existingTriggers.map(SnippetTrigger.key))
        var result: [SnippetBackup] = []
        for snippet in imported ?? [] {
            guard SnippetTrigger.isUsable(snippet.trigger),
                !snippet.expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                taken.insert(SnippetTrigger.key(snippet.trigger)).inserted
            else { continue }
            result.append(SnippetBackup(trigger: SnippetTrigger.normalized(snippet.trigger), expansion: snippet.expansion))
        }
        return result
    }
}

enum SnippetValidation {
    enum Failure: Equatable {
        case emptyTrigger
        case unusableTrigger
        case emptyExpansion
        case duplicateTrigger
    }

    /// Checks a snippet before saving. `existingTriggers` are the other snippets' triggers (leave out the
    /// one being edited).
    static func validate(trigger: String, expansion: String, existingTriggers: [String]) -> Failure? {
        if SnippetTrigger.normalized(trigger).isEmpty { return .emptyTrigger }
        if !SnippetTrigger.isUsable(trigger) { return .unusableTrigger }
        if expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyExpansion }
        let key = SnippetTrigger.key(trigger)
        if existingTriggers.contains(where: { SnippetTrigger.key($0) == key }) { return .duplicateTrigger }
        return nil
    }
}
