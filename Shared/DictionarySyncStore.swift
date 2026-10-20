import Foundation
import SwiftData

/// Reads the dictionary store for the sync and writes a merged state back to it. It is a model actor,
/// like `WordReplacementStore`, so the work happens off the main actor; the screens see the saved changes
/// through their own contexts.
@ModelActor
actor DictionarySyncStore {
    private struct Entry {
        let item: DictionarySyncItem
        let model: any PersistentModel
    }

    /// The state of the store against what the last sync left (see `DictionarySyncMerge.capture`).
    func capture(last: DictionarySyncState, now: Date) throws -> DictionarySyncState {
        let items = try entries().map(\.item)
        return DictionarySyncMerge.capture(current: items, last: last, now: now)
    }

    /// Makes the store match `merged`. `local` is the capture the merge started from: an item that
    /// changed in the store since then is left alone (the next sync takes it as an edit made now), and so
    /// is one the user deleted since then (it is not put back).
    func apply(merged: DictionarySyncState, local: DictionarySyncState) throws {
        var byKey: [DictionarySyncKey: Entry] = [:]
        for entry in try entries() where byKey[entry.item.key] == nil {
            byKey[entry.item.key] = entry
        }

        do {
            for (key, entry) in byKey {
                guard let captured = local.records[key], captured.payload == entry.item.payload else { continue }
                guard let record = merged.records[key] else {
                    modelContext.delete(entry.model)
                    continue
                }
                if record.payload != entry.item.payload {
                    update(entry.model, to: record.payload)
                }
            }
            for (key, record) in merged.records where byKey[key] == nil && local.records[key] == nil {
                insert(record)
            }
            if modelContext.hasChanges { try modelContext.save() }
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    // MARK: Reading

    private func entries() throws -> [Entry] {
        var result: [Entry] = []

        let words = try modelContext.fetch(FetchDescriptor<VocabularyWord>())
            .sorted { ($0.dateAdded, $0.word) < ($1.dateAdded, $1.word) }
        for word in words {
            let term = DictionarySyncFormat.normalized(word.word)
            let payload = DictionarySyncPayload.vocabulary(term: term)
            guard payload.isUsable else { continue }
            result.append(
                Entry(
                    item: DictionarySyncItem(key: .vocabulary(term: term), payload: payload, createdAt: word.dateAdded),
                    model: word))
        }

        let replacements = try modelContext.fetch(FetchDescriptor<WordReplacement>())
            .sorted { ($0.dateAdded, $0.id.uuidString) < ($1.dateAdded, $1.id.uuidString) }
        for replacement in replacements {
            let payload = DictionarySyncPayload.replacement(
                sources: WordReplacementVariants.parse(replacement.originalText),
                replacement: WordReplacementVariants.destinationKey(for: replacement.replacementText))
            guard payload.isUsable else { continue }
            result.append(
                Entry(
                    item: DictionarySyncItem(
                        key: DictionarySyncKey(kind: .replacement, id: replacement.id.uuidString),
                        payload: payload, createdAt: replacement.dateAdded),
                    model: replacement))
        }

        let snippets = try modelContext.fetch(FetchDescriptor<Snippet>())
            .sorted { ($0.dateAdded, $0.id.uuidString) < ($1.dateAdded, $1.id.uuidString) }
        for snippet in snippets {
            let payload = DictionarySyncPayload.snippet(
                trigger: SnippetTrigger.normalized(snippet.trigger),
                expansion: Snippet.cleanedExpansion(snippet.expansion))
            guard payload.isUsable else { continue }
            result.append(
                Entry(
                    item: DictionarySyncItem(
                        key: DictionarySyncKey(kind: .snippet, id: snippet.id.uuidString),
                        payload: payload, createdAt: snippet.dateAdded),
                    model: snippet))
        }
        return result
    }

    // MARK: Writing

    private func update(_ model: any PersistentModel, to payload: DictionarySyncPayload) {
        switch (model, payload) {
        case (let word as VocabularyWord, .vocabulary(let term)):
            word.word = term
        case (let replacement as WordReplacement, .replacement(let sources, let destination)):
            replacement.originalText = WordReplacementVariants.serialize(sources)
            replacement.replacementText = destination
        case (let snippet as Snippet, .snippet(let trigger, let expansion)):
            snippet.trigger = trigger
            snippet.expansion = expansion
        default:
            break
        }
    }

    private func insert(_ record: DictionarySyncRecord) {
        switch record.payload {
        case .vocabulary(let term):
            modelContext.insert(VocabularyWord(word: term, dateAdded: record.createdAt))
        case .replacement(let sources, let destination):
            let replacement = WordReplacement(
                originalText: WordReplacementVariants.serialize(sources), replacementText: destination,
                dateAdded: record.createdAt)
            if let id = UUID(uuidString: record.key.id) { replacement.id = id }
            modelContext.insert(replacement)
        case .snippet(let trigger, let expansion):
            let snippet = Snippet(trigger: trigger, expansion: expansion, dateAdded: record.createdAt)
            if let id = UUID(uuidString: record.key.id) { snippet.id = id }
            modelContext.insert(snippet)
        }
    }
}
