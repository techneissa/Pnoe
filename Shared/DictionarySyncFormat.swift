import CryptoKit
import Foundation

/// The sync file is the dictionary export archive (`pnoe.dictionary`, schema 1) with stable ids, edit
/// dates, snippets and the deletions added as optional keys, so the manual import still reads it.
enum DictionarySyncFormat {
    static func archive(
        from state: DictionarySyncState, deviceID: String, now: Date,
        storeID: String? = nil, lastSyncAt: Date? = nil
    ) -> DictionaryArchive {
        func sorted(_ kind: DictionarySyncKind) -> [DictionarySyncRecord] {
            state.records.values
                .filter { $0.key.kind == kind }
                .sorted { ($0.createdAt, $0.key.id) < ($1.createdAt, $1.key.id) }
        }

        let vocabulary = sorted(.vocabulary).compactMap { record -> DictionaryVocabularyEntry? in
            guard case .vocabulary(let term) = record.payload else { return nil }
            return DictionaryVocabularyEntry(
                term: term, createdAt: record.createdAt, id: record.key.id, modifiedAt: record.modifiedAt)
        }
        let replacements = sorted(.replacement).compactMap { record -> DictionaryReplacementEntry? in
            guard case .replacement(let sources, let replacement) = record.payload else { return nil }
            return DictionaryReplacementEntry(
                sources: sources, replacement: replacement, createdAt: record.createdAt,
                id: record.key.id, modifiedAt: record.modifiedAt)
        }
        let snippets = sorted(.snippet).compactMap { record -> DictionarySnippetEntry? in
            guard case .snippet(let trigger, let expansion) = record.payload else { return nil }
            return DictionarySnippetEntry(
                trigger: trigger, expansion: expansion, createdAt: record.createdAt,
                id: record.key.id, modifiedAt: record.modifiedAt)
        }
        let tombstones = state.tombstones
            .map { DictionaryTombstoneEntry(kind: $0.key.kind.rawValue, id: $0.key.id, deletedAt: $0.value) }
            .sorted { ($0.kind, $0.id) < ($1.kind, $1.id) }

        return DictionaryArchive(
            exportedAt: now,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            vocabulary: vocabulary,
            replacements: replacements,
            snippets: snippets,
            sync: DictionarySyncMetadata(
                deviceID: deviceID, writtenAt: now, tombstones: tombstones, storeID: storeID, lastSyncAt: lastSyncAt))
    }

    /// Reads the records of an archive. An entry without an id or an edit date (an export from before
    /// sync, or one made by hand) gets an id every Mac works out the same way and its creation date.
    /// Dates later than `now` plus five minutes come from a wrong clock and count as `now`.
    static func state(from archive: DictionaryArchive, now: Date) -> DictionarySyncState {
        DictionarySyncMerge.clamped(unclampedState(from: archive), now: now)
    }

    static func unclampedState(from archive: DictionaryArchive) -> DictionarySyncState {
        var state = DictionarySyncState()

        func add(_ key: DictionarySyncKey, _ payload: DictionarySyncPayload, created: Date?, modified: Date?) {
            let createdAt = DictionarySyncMerge.floored(created ?? modified ?? .distantPast)
            let modifiedAt = DictionarySyncMerge.floored(modified ?? created ?? .distantPast)
            let record = DictionarySyncRecord(
                key: key, payload: payload, createdAt: min(createdAt, modifiedAt), modifiedAt: modifiedAt)
            guard payload.isUsable else { return }
            if let existing = state.records[key], existing.modifiedAt >= record.modifiedAt { return }
            state.records[key] = record
        }

        for entry in archive.vocabulary {
            let payload = DictionarySyncPayload.vocabulary(term: normalized(entry.term))
            add(.vocabulary(term: entry.term), payload, created: entry.createdAt, modified: entry.modifiedAt)
        }
        for entry in archive.replacements {
            let payload = DictionarySyncPayload.replacement(
                sources: WordReplacementVariants.parse(WordReplacementVariants.serialize(entry.sources.map(normalized))),
                replacement: WordReplacementVariants.destinationKey(for: entry.replacement))
            let id = validID(entry.id) ?? derivedID(.replacement, payload.naturalKey)
            add(
                DictionarySyncKey(kind: .replacement, id: id), payload,
                created: entry.createdAt, modified: entry.modifiedAt)
        }
        for entry in archive.snippets ?? [] {
            let payload = DictionarySyncPayload.snippet(
                trigger: SnippetTrigger.normalized(entry.trigger), expansion: Snippet.cleanedExpansion(entry.expansion))
            let id = validID(entry.id) ?? derivedID(.snippet, payload.naturalKey)
            add(
                DictionarySyncKey(kind: .snippet, id: id), payload,
                created: entry.createdAt, modified: entry.modifiedAt)
        }
        for tombstone in archive.sync?.tombstones ?? [] {
            guard let kind = DictionarySyncKind(rawValue: tombstone.kind) else { continue }
            let key = DictionarySyncKey(kind: kind, id: tombstone.id)
            let deletedAt = DictionarySyncMerge.floored(tombstone.deletedAt)
            state.tombstones[key] = max(state.tombstones[key] ?? .distantPast, deletedAt)
        }
        return state
    }

    static func encode(
        _ state: DictionarySyncState, deviceID: String, now: Date, storeID: String? = nil, lastSyncAt: Date? = nil
    ) throws -> Data {
        try DictionaryImportExportService.encodeArchive(
            archive(from: state, deviceID: deviceID, now: now, storeID: storeID, lastSyncAt: lastSyncAt))
    }

    /// Throws `DictionaryArchiveError` when the data is not a Pnoe dictionary this version can read.
    static func decode(_ data: Data, now: Date) throws -> DictionarySyncFileContents {
        let archive = try DictionaryImportExportService.decodeArchiveData(data).archive
        let raw = unclampedState(from: archive)
        let state = DictionarySyncMerge.clamped(raw, now: now)
        return DictionarySyncFileContents(
            state: state, hadFutureDates: state != raw, deviceID: archive.sync?.deviceID,
            storeID: archive.sync?.storeID, lastSyncAt: archive.sync?.lastSyncAt)
    }

    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    private static func validID(_ id: String?) -> String? {
        guard let id, let uuid = UUID(uuidString: id) else { return nil }
        return uuid.uuidString
    }

    /// The same text gives the same id on every Mac.
    static func derivedID(_ kind: DictionarySyncKind, _ naturalKey: String) -> String {
        let digest = Array(SHA256.hash(data: Data("\(kind.rawValue)\u{0}\(naturalKey)".utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )).uuidString
    }
}

struct DictionarySyncFileContents: Sendable {
    var state: DictionarySyncState
    /// The file had dates from a wrong clock. They were clamped, and the file is written again so they
    /// don't keep counting as "now" on every later pass.
    var hadFutureDates = false
    var deviceID: String?
    var storeID: String?
    var lastSyncAt: Date?
}

/// What this Mac remembers between passes, in the sync file's own format: the state the last pass left
/// (to tell a local edit from a remote one), the id of this Mac, the store the state was made for and
/// when the last pass finished. Never in the iCloud Drive: it describes this Mac's store only.
struct DictionarySyncLocalStateFile: Sendable {
    struct Contents: Sendable {
        var deviceID: String
        var storeID: String
        var lastSyncAt: Date?
        var state: DictionarySyncState
    }

    let url: URL

    /// `nil` when there is no file yet or it can't be read. The pass then is a first merge, which merges
    /// and never deletes on this Mac or from the file.
    func load(now: Date) -> Contents? {
        guard let data = try? Data(contentsOf: url),
            let decoded = try? DictionarySyncFormat.decode(data, now: now),
            let deviceID = decoded.deviceID, let storeID = decoded.storeID
        else { return nil }
        return Contents(deviceID: deviceID, storeID: storeID, lastSyncAt: decoded.lastSyncAt, state: decoded.state)
    }

    func save(_ contents: Contents, now: Date) throws {
        let data = try DictionarySyncFormat.encode(
            contents.state, deviceID: contents.deviceID, now: now, storeID: contents.storeID,
            lastSyncAt: contents.lastSyncAt)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
