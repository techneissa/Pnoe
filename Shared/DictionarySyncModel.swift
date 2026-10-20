import Foundation

// The value types and the merge of the iCloud Drive dictionary sync. Nothing here touches SwiftData
// or the disk, so two Macs can be played against each other in a test.

enum DictionarySyncKind: String, Codable, CaseIterable, Sendable {
    case vocabulary
    case replacement
    case snippet
}

/// Which item a record or a tombstone is about. Vocabulary has no id of its own, so its id is the
/// case-folded term; replacements and snippets use the id of their model.
struct DictionarySyncKey: Hashable, Sendable {
    let kind: DictionarySyncKind
    let id: String

    static func vocabulary(term: String) -> DictionarySyncKey {
        DictionarySyncKey(kind: .vocabulary, id: WordReplacementVariants.key(for: term))
    }
}

enum DictionarySyncPayload: Equatable, Sendable {
    case vocabulary(term: String)
    case replacement(sources: [String], replacement: String)
    case snippet(trigger: String, expansion: String)

    var kind: DictionarySyncKind {
        switch self {
        case .vocabulary: return .vocabulary
        case .replacement: return .replacement
        case .snippet: return .snippet
        }
    }

    /// What two items of one kind must not share: the term, the replacement text, the trigger.
    var naturalKey: String {
        switch self {
        case .vocabulary(let term): return WordReplacementVariants.key(for: term)
        case .replacement(_, let replacement): return WordReplacementVariants.destinationKey(for: replacement)
        case .snippet(let trigger, _): return SnippetTrigger.key(trigger)
        }
    }

    var isUsable: Bool {
        switch self {
        case .vocabulary(let term):
            return !WordReplacementVariants.key(for: term).isEmpty
        case .replacement(let sources, let replacement):
            return !sources.isEmpty
                && sources.allSatisfy { !$0.isEmpty && !$0.contains(",") }
                && !WordReplacementVariants.destinationKey(for: replacement).isEmpty
        case .snippet(let trigger, let expansion):
            return SnippetTrigger.isUsable(trigger)
                && !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// A text that orders two payloads the same way on every Mac, to settle edits with the same date.
    var sortText: String {
        switch self {
        case .vocabulary(let term): return "v\u{0}\(term)"
        case .replacement(let sources, let replacement):
            return "r\u{0}\(replacement)\u{0}\(sources.joined(separator: "\u{1}"))"
        case .snippet(let trigger, let expansion): return "s\u{0}\(trigger)\u{0}\(expansion)"
        }
    }
}

struct DictionarySyncRecord: Equatable, Sendable {
    var key: DictionarySyncKey
    var payload: DictionarySyncPayload
    var createdAt: Date
    var modifiedAt: Date
}

/// Everything one Mac knows about the dictionary: the live items and the deletions it must still pass on.
struct DictionarySyncState: Equatable, Sendable {
    var records: [DictionarySyncKey: DictionarySyncRecord] = [:]
    var tombstones: [DictionarySyncKey: Date] = [:]
}

/// An item as it is in the store right now.
struct DictionarySyncItem: Equatable, Sendable {
    let key: DictionarySyncKey
    let payload: DictionarySyncPayload
    let createdAt: Date
}

enum DictionarySyncMerge {
    /// How long a deletion is kept. A Mac that was off for longer than this can bring an item back.
    static let tombstoneLifetime: TimeInterval = 90 * 24 * 60 * 60

    /// Whole seconds, the resolution of the dates in the file.
    static func floored(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    // MARK: Local changes

    /// The state of this Mac: `current` is what the store holds now, `last` what the previous sync left.
    /// An item that matches its last record keeps that record's date; a changed one is stamped `now`; a
    /// new one takes its creation date; one that disappeared becomes a tombstone stamped `now`.
    static func capture(
        current: [DictionarySyncItem], last: DictionarySyncState, now: Date
    ) -> DictionarySyncState {
        let now = floored(now)
        var state = DictionarySyncState()
        state.tombstones = last.tombstones
        for item in current where state.records[item.key] == nil {
            if let previous = last.records[item.key] {
                if previous.payload == item.payload {
                    state.records[item.key] = previous
                } else {
                    state.records[item.key] = DictionarySyncRecord(
                        key: item.key, payload: item.payload, createdAt: previous.createdAt, modifiedAt: now)
                }
            } else {
                // A word that was deleted and typed in again counts as an edit made now.
                let modified = last.tombstones[item.key].map { max(now, $0.addingTimeInterval(1)) }
                    ?? min(floored(item.createdAt), now)
                state.records[item.key] = DictionarySyncRecord(
                    key: item.key, payload: item.payload, createdAt: floored(item.createdAt), modifiedAt: modified)
            }
        }
        for key in last.records.keys where state.records[key] == nil {
            state.tombstones[key] = max(state.tombstones[key] ?? .distantPast, now)
        }
        for (key, record) in state.records {
            if let deletedAt = state.tombstones[key], record.modifiedAt > deletedAt {
                state.tombstones[key] = nil
            }
        }
        return state
    }

    // MARK: Merge

    /// Joins two states. The result is the same whichever side is `a`, and merging it with either side
    /// again changes nothing, so any number of Macs settle on one state.
    static func merge(_ a: DictionarySyncState, _ b: DictionarySyncState, now: Date) -> DictionarySyncState {
        var state = DictionarySyncState()
        for record in Array(a.records.values) + Array(b.records.values) {
            if let existing = state.records[record.key] {
                var winner = newer(existing, record)
                winner.createdAt = min(existing.createdAt, record.createdAt)
                state.records[record.key] = winner
            } else {
                state.records[record.key] = record
            }
        }
        state.tombstones = a.tombstones.merging(b.tombstones, uniquingKeysWith: max)

        // A deletion beats an edit made before it (or at the same second); a later edit brings the item back.
        for (key, deletedAt) in state.tombstones {
            if let record = state.records[key], record.modifiedAt > deletedAt {
                state.tombstones[key] = nil
            } else {
                state.records[key] = nil
            }
        }
        let oldest = now.addingTimeInterval(-tombstoneLifetime)
        state.tombstones = state.tombstones.filter { $0.value >= oldest }

        return normalized(state)
    }

    private static func newer(_ lhs: DictionarySyncRecord, _ rhs: DictionarySyncRecord) -> DictionarySyncRecord {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt ? lhs : rhs }
        return lhs.payload.sortText >= rhs.payload.sortText ? lhs : rhs
    }

    // MARK: Duplicates and conflicts

    /// Leaves one item per snippet trigger and per replacement text, and no word that two replacement
    /// rules both want, however the Macs got there (each added the same thing before the first sync).
    private static func normalized(_ input: DictionarySyncState) -> DictionarySyncState {
        var state = input
        state.records = state.records.filter { $0.value.payload.isUsable }

        for kind in [DictionarySyncKind.snippet, .replacement] {
            let ofKind = state.records.values.filter { $0.key.kind == kind }
            for group in Dictionary(grouping: ofKind, by: { $0.payload.naturalKey }).values where group.count > 1 {
                let byAge = group.sorted { ($0.modifiedAt, $0.key.id) < ($1.modifiedAt, $1.key.id) }
                let newestEdit = group.reduce(group[0]) { newer($0, $1) }
                let winnerID = group.map(\.key.id).min()!

                var winner = group.first { $0.key.id == winnerID }!
                winner.createdAt = group.map(\.createdAt).min()!
                winner.modifiedAt = group.map(\.modifiedAt).max()!
                switch newestEdit.payload {
                case .replacement(_, let destination):
                    let sources = byAge.flatMap { record -> [String] in
                        if case .replacement(let own, _) = record.payload { return own }
                        return []
                    }
                    winner.payload = .replacement(
                        sources: WordReplacementVariants.parse(WordReplacementVariants.serialize(sources)),
                        replacement: destination)
                default:
                    winner.payload = newestEdit.payload
                }
                for loser in group where loser.key.id != winnerID {
                    state.records[loser.key] = nil
                    state.tombstones[loser.key] = max(state.tombstones[loser.key] ?? .distantPast, winner.modifiedAt)
                }
                state.records[winner.key] = winner
            }
        }

        // A source word belongs to one rule (the oldest edit keeps it), and no rule may close a loop.
        var detector = WordReplacementVariants.CycleDetector(records: [])
        var claimed = Set<String>()
        let rules = state.records.values
            .filter { $0.key.kind == .replacement }
            .sorted { ($0.modifiedAt, $0.key.id) < ($1.modifiedAt, $1.key.id) }
        for rule in rules {
            guard case .replacement(let sources, let destination) = rule.payload else { continue }
            var kept: [String] = []
            for source in sources {
                let sourceKey = WordReplacementVariants.key(for: source)
                guard !claimed.contains(sourceKey),
                    detector.insertIfAcyclic(source: source, destination: destination)
                else { continue }
                claimed.insert(sourceKey)
                kept.append(source)
            }
            if kept.isEmpty {
                state.records[rule.key] = nil
                state.tombstones[rule.key] = max(state.tombstones[rule.key] ?? .distantPast, rule.modifiedAt)
            } else if kept != sources {
                state.records[rule.key]?.payload = .replacement(sources: kept, replacement: destination)
            }
        }
        return state
    }
}
