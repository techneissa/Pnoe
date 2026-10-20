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

    /// How the entry is named to the user.
    var displayText: String {
        switch self {
        case .vocabulary(let term): return term
        case .replacement(let sources, let replacement): return "\(sources.joined(separator: ", ")) → \(replacement)"
        case .snippet(let trigger, _): return trigger
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
    /// A record this version can't use (an empty term, a trigger without a letter) stays in the state, so
    /// the file keeps what a newer version wrote; the store skips it.
    private static func normalized(_ input: DictionarySyncState) -> DictionarySyncState {
        var state = input

        for kind in [DictionarySyncKind.snippet, .replacement] {
            let ofKind = state.records.values.filter { $0.key.kind == kind && $0.payload.isUsable }
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

        // A source word belongs to one rule, the newest edit, and no rule may close a loop. A rule is
        // never left without a source: one whose every source is taken keeps them (the entry stays).
        var detector = WordReplacementVariants.CycleDetector(records: [])
        var claimed = Set<String>()
        let rules = state.records.values
            .filter { $0.key.kind == .replacement && $0.payload.isUsable }
            .sorted { ($0.modifiedAt, $0.key.id) > ($1.modifiedAt, $1.key.id) }
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
            if !kept.isEmpty, kept != sources {
                state.records[rule.key]?.payload = .replacement(sources: kept, replacement: destination)
            }
        }
        return state
    }

    // MARK: Before a pass

    /// How far ahead of this Mac's clock a date in a file may be before it is taken for a wrong clock.
    static let clockSkewAllowance: TimeInterval = 5 * 60

    /// A date later than `now` plus the allowance is a wrong clock on some Mac; it counts as `now`, so one
    /// far-future deletion or edit can't win against everything for good.
    static func clamped(_ state: DictionarySyncState, now: Date) -> DictionarySyncState {
        let limit = now.addingTimeInterval(clockSkewAllowance)
        var result = state
        for (key, record) in state.records {
            var fixed = record
            if fixed.modifiedAt > limit { fixed.modifiedAt = floored(now) }
            if fixed.createdAt > fixed.modifiedAt { fixed.createdAt = fixed.modifiedAt }
            result.records[key] = fixed
        }
        for (key, deletedAt) in state.tombstones where deletedAt > limit {
            result.tombstones[key] = floored(now)
        }
        return result
    }

    /// This Mac's state as it goes into the merge.
    /// - A first merge (no state of this Mac to compare with, or a store that is not the one the state was
    ///   made for) has no deletions of its own, and a remote deletion must not take an entry this Mac
    ///   has: those entries count as edited now.
    /// - After longer than the tombstone lifetime without a pass, other Macs' deletions may have expired
    ///   from the file. An entry unchanged since the last pass and missing from the file was then most
    ///   likely deleted, so it is left out (not uploaded); only entries edited since go up.
    /// - `keeping` are entries the user chose to keep: they count as edited now and go back up.
    static func prepared(
        local: DictionarySyncState, remote: DictionarySyncState, now: Date,
        lastSyncAt: Date?, isFirstMerge: Bool, keeping: Set<DictionarySyncKey>
    ) -> DictionarySyncState {
        var state = local
        let now = floored(now)
        if isFirstMerge {
            for (key, record) in local.records {
                if let deletedAt = remote.tombstones[key], record.modifiedAt <= deletedAt {
                    state.records[key]?.modifiedAt = max(now, deletedAt.addingTimeInterval(1))
                }
            }
        } else if let lastSyncAt, now.timeIntervalSince(lastSyncAt) > tombstoneLifetime {
            for (key, record) in local.records
            where record.modifiedAt <= lastSyncAt && remote.records[key] == nil && !keeping.contains(key) {
                state.records[key] = nil
            }
        }
        for key in keeping {
            guard var record = state.records[key] ?? local.records[key] else { continue }
            let deletedAt = remote.tombstones[key] ?? .distantPast
            record.modifiedAt = max(record.modifiedAt, now, deletedAt.addingTimeInterval(1))
            state.records[key] = record
        }
        return state
    }

    /// The entries of `local` the merged state no longer has: deleted on another Mac, or left out because
    /// of the lifetime rule. An item that only became part of another item (two snippets with one trigger
    /// merged into one) is not a removal.
    static func removals(local: DictionarySyncState, merged: DictionarySyncState) -> [DictionarySyncRecord] {
        var kept = Set<String>()
        for record in merged.records.values where record.payload.isUsable {
            kept.insert("\(record.key.kind.rawValue)\u{0}\(record.payload.naturalKey)")
        }
        return local.records.values
            .filter {
                merged.records[$0.key] == nil
                    && !kept.contains("\($0.key.kind.rawValue)\u{0}\($0.payload.naturalKey)")
            }
            .sorted { ($0.key.kind.rawValue, $0.payload.displayText) < ($1.key.kind.rawValue, $1.payload.displayText) }
    }
}
