import Foundation
import SwiftData
import os

/// Reads and changes saved snippets. Matching lives in `SnippetMatcher`.
@MainActor
enum SnippetService {
    private static let logger = Logger(subsystem: "com.techneissa.pnoe", category: "SnippetService")

    static func rules(using context: ModelContext) -> [SnippetRule] {
        do {
            return try context.fetch(FetchDescriptor<Snippet>()).map {
                SnippetRule(trigger: $0.trigger, expansion: $0.expansion)
            }
        } catch {
            logger.error("Could not load snippets: \(error, privacy: .public)")
            return []
        }
    }

    /// Adds a snippet. Returns an error message, or nil on success.
    @discardableResult
    static func add(trigger: String, expansion: String, existing: [Snippet], context: ModelContext) -> String? {
        if let message = validationMessage(
            trigger: trigger, expansion: expansion, existingTriggers: existing.map(\.trigger))
        {
            return message
        }
        let snippet = Snippet(trigger: trigger, expansion: expansion)
        context.insert(snippet)
        return save(context, failure: String(localized: "Failed to add snippet: %@"), undo: { context.delete(snippet) })
    }

    /// Updates a snippet. Returns an error message, or nil on success.
    @discardableResult
    static func update(
        _ snippet: Snippet, trigger: String, expansion: String, existing: [Snippet], context: ModelContext
    ) -> String? {
        let others = existing.filter { $0.persistentModelID != snippet.persistentModelID }.map(\.trigger)
        if let message = validationMessage(trigger: trigger, expansion: expansion, existingTriggers: others) {
            return message
        }
        snippet.trigger = SnippetTrigger.normalized(trigger)
        snippet.expansion = Snippet.cleanedExpansion(expansion)
        return save(context, failure: String(localized: "Failed to save snippet: %@"), undo: { context.rollback() })
    }

    @discardableResult
    static func remove(_ snippet: Snippet, context: ModelContext) -> String? {
        context.delete(snippet)
        return save(context, failure: String(localized: "Failed to remove snippet: %@"), undo: { context.rollback() })
    }

    /// Adds snippets from a backup, keeping any snippet whose trigger is already saved.
    static func importBackup(_ imported: [SnippetBackup]?, context: ModelContext) throws -> Int {
        let existing = try context.fetch(FetchDescriptor<Snippet>())
        let toAdd = SnippetBackupPayload.snippetsToImport(imported, existingTriggers: existing.map(\.trigger))
        for item in toAdd {
            context.insert(Snippet(trigger: item.trigger, expansion: item.expansion))
        }
        if !toAdd.isEmpty { try context.save() }
        return toAdd.count
    }

    static func backupItems(context: ModelContext) -> [SnippetBackup] {
        let snippets = (try? context.fetch(FetchDescriptor<Snippet>())) ?? []
        return snippets
            .sorted { ($0.dateAdded, $0.id.uuidString) < ($1.dateAdded, $1.id.uuidString) }
            .map { SnippetBackup(trigger: $0.trigger, expansion: $0.expansion) }
    }

    static func validationMessage(trigger: String, expansion: String, existingTriggers: [String]) -> String? {
        switch SnippetValidation.validate(trigger: trigger, expansion: expansion, existingTriggers: existingTriggers) {
        case nil:
            return nil
        case .emptyTrigger:
            return String(localized: "Enter a trigger phrase")
        case .unusableTrigger:
            return String(localized: "The trigger phrase needs at least one letter or number")
        case .emptyExpansion:
            return String(localized: "Enter the text to insert")
        case .duplicateTrigger:
            return String(localized: "A snippet with this trigger already exists")
        }
    }

    private static func save(_ context: ModelContext, failure: String, undo: () -> Void) -> String? {
        do {
            try context.save()
            return nil
        } catch {
            undo()
            return String(format: failure, error.localizedDescription)
        }
    }
}
