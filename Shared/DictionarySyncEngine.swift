import Foundation

/// An entry this Mac would lose in a pass: deleted on another Mac, or left out by the lifetime rule.
struct DictionarySyncRemoval: Equatable, Sendable {
    let key: DictionarySyncKey
    let title: String
}

/// What a pass would do to this Mac's dictionary, worked out without changing anything.
struct DictionarySyncPlan: Equatable, Sendable {
    var added: Int
    var updated: Int
    var removals: [DictionarySyncRemoval]

    var removalKeys: Set<DictionarySyncKey> { Set(removals.map(\.key)) }
}

struct DictionarySyncReport: Equatable, Sendable {
    let syncedAt: Date
    let added: Int
    let updated: Int
    let removed: Int
    /// The sync file was written (it was missing, or this Mac had something the file lacked).
    let wroteFile: Bool
}

enum DictionarySyncDeletionChoice: Sendable {
    /// Take the deletions into this Mac's dictionary.
    case remove
    /// Keep the entries here and put them back into the file.
    case keep
}

/// Lets the Cancel button stop a pass before it writes.
final class DictionarySyncCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func check() throws {
        if isCancelled { throw DictionarySyncError.cancelled }
    }
}

/// One sync, in two steps. `plan` reads and merges without changing anything and says which entries
/// this Mac would lose; the user confirms those. `commit` then reads and merges again under one file
/// coordination, writes the file if it changed, and applies the result to the store.
///
/// Passes must not overlap; the controller runs one at a time. A pass that fails leaves the remembered
/// state alone, so the next one starts from the same place.
actor DictionarySyncEngine {
    private let store: DictionarySyncStore
    private let drive: any DictionarySyncDrive
    private let stateFile: DictionarySyncLocalStateFile
    private let storeIdentity: @Sendable () -> String
    private let clock: @Sendable () -> Date

    /// - Parameter storeIdentity: a token that belongs to this dictionary store and changes when the
    ///   store is reset or restored (`DictionaryStoreIdentity`). A remembered state made for another
    ///   token is not trusted.
    init(
        store: DictionarySyncStore,
        drive: any DictionarySyncDrive,
        stateFile: DictionarySyncLocalStateFile,
        storeIdentity: @escaping @Sendable () -> String,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.drive = drive
        self.stateFile = stateFile
        self.storeIdentity = storeIdentity
        self.clock = clock
    }

    func plan(cancellation: DictionarySyncCancellation = DictionarySyncCancellation()) async throws
        -> DictionarySyncPlan
    {
        let context = try await startPass()
        try cancellation.check()
        let contents = try await readDrive()
        let combined = try Self.combine(contents, with: context, keeping: [])
        return DictionarySyncPlan(
            added: Self.addedCount(local: context.local, merged: combined.merged),
            updated: Self.updatedCount(local: context.local, merged: combined.merged),
            removals: combined.removals)
    }

    /// - Parameter reviewed: the removals the user was shown. If the pass would remove anything else,
    ///   it stops with `changedDuringReview` and nothing changes.
    func commit(
        choice: DictionarySyncDeletionChoice,
        reviewed: Set<DictionarySyncKey>,
        cancellation: DictionarySyncCancellation = DictionarySyncCancellation()
    ) async throws -> DictionarySyncReport {
        let context = try await startPass()
        try cancellation.check()

        let drive = self.drive
        let (combined, wroteFile) = try await Task.detached(priority: .utility) {
            var result: Combined?
            var wrote = false
            try drive.exchange { contents in
                var combined = try Self.combine(contents, with: context, keeping: [])
                let removalKeys = Set(combined.removals.map(\.key))
                guard removalKeys.isSubset(of: reviewed) else { throw DictionarySyncError.changedDuringReview }
                if choice == .keep, !removalKeys.isEmpty {
                    combined = try Self.combine(contents, with: context, keeping: removalKeys)
                }
                try cancellation.check()
                result = combined
                wrote = combined.needsWrite
                let data =
                    combined.needsWrite
                    ? try DictionarySyncFormat.encode(
                        combined.merged, deviceID: context.deviceID, now: context.now)
                    : nil
                return DictionarySyncExchangeResult(output: data, consumedConflicts: combined.consumed)
            }
            return (result!, wrote)
        }.value

        try cancellation.check()
        do {
            try await store.apply(merged: combined.merged, local: context.local)
        } catch {
            throw DictionarySyncError.storeFailed
        }
        try? stateFile.save(
            .init(
                deviceID: context.deviceID, storeID: context.storeID, lastSyncAt: context.now,
                state: combined.merged),
            now: context.now)
        return DictionarySyncReport(
            syncedAt: context.now,
            added: Self.addedCount(local: context.local, merged: combined.merged),
            updated: Self.updatedCount(local: context.local, merged: combined.merged),
            removed: Self.removalCount(local: context.local, merged: combined.merged),
            wroteFile: wroteFile)
    }

    // MARK: Steps

    private struct PassContext: Sendable {
        let deviceID: String
        let storeID: String
        let now: Date
        let local: DictionarySyncState
        let lastSyncAt: Date?
        let isFirstMerge: Bool
    }

    private struct Combined: Sendable {
        var merged: DictionarySyncState
        var removals: [DictionarySyncRemoval]
        var consumed: Set<Int>
        var needsWrite: Bool
    }

    /// Captures this Mac's changes against the remembered state. A state that is missing, or was made for
    /// another store, is not trusted: this Mac then has no deletions of its own and keeps what it has.
    private func startPass() async throws -> PassContext {
        let now = DictionarySyncMerge.floored(clock())
        let storeID = storeIdentity()
        let remembered = stateFile.load(now: now)
        let isFirstMerge = remembered == nil || remembered?.storeID != storeID
        let local: DictionarySyncState
        do {
            local = try await store.capture(
                last: isFirstMerge ? DictionarySyncState() : remembered!.state, now: now)
        } catch {
            throw DictionarySyncError.storeFailed
        }
        return PassContext(
            deviceID: remembered?.deviceID ?? UUID().uuidString, storeID: storeID, now: now, local: local,
            lastSyncAt: isFirstMerge ? nil : remembered?.lastSyncAt, isFirstMerge: isFirstMerge)
    }

    private func readDrive() async throws -> DictionarySyncDriveContents {
        let drive = self.drive
        return try await Task.detached(priority: .utility) { try drive.read() }.value
    }

    /// Merges the file and its conflict copies with this Mac's state. A file this version can't read
    /// stops the pass here, before anything is written; a conflict copy it can't read is left alone.
    private static func combine(
        _ contents: DictionarySyncDriveContents, with context: PassContext, keeping: Set<DictionarySyncKey>
    ) throws -> Combined {
        var remote = DictionarySyncState()
        var mainState: DictionarySyncState?
        var mainHadFutureDates = false
        if let data = contents.main {
            guard let decoded = try? DictionarySyncFormat.decode(data, now: context.now) else {
                throw DictionarySyncError.unreadableFile
            }
            mainState = decoded.state
            mainHadFutureDates = decoded.hadFutureDates
            remote = decoded.state
        }
        var consumed = Set<Int>()
        for (index, data) in contents.conflicts.enumerated() {
            guard let decoded = try? DictionarySyncFormat.decode(data, now: context.now) else { continue }
            remote = DictionarySyncMerge.merge(remote, decoded.state, now: context.now)
            consumed.insert(index)
        }

        let prepared = DictionarySyncMerge.prepared(
            local: context.local, remote: remote, now: context.now, lastSyncAt: context.lastSyncAt,
            isFirstMerge: context.isFirstMerge, keeping: keeping)
        let merged = DictionarySyncMerge.merge(prepared, remote, now: context.now)
        let removals = DictionarySyncMerge.removals(local: context.local, merged: merged)
            .map { DictionarySyncRemoval(key: $0.key, title: $0.payload.displayText) }
        return Combined(
            merged: merged, removals: removals, consumed: consumed,
            needsWrite: mainState == nil || merged != mainState || mainHadFutureDates)
    }

    private static func addedCount(local: DictionarySyncState, merged: DictionarySyncState) -> Int {
        merged.records.values.filter { $0.payload.isUsable && local.records[$0.key] == nil }.count
    }

    private static func updatedCount(local: DictionarySyncState, merged: DictionarySyncState) -> Int {
        merged.records.values.filter { record in
            guard let before = local.records[record.key] else { return false }
            return before.payload != record.payload && record.payload.isUsable
        }.count
    }

    private static func removalCount(local: DictionarySyncState, merged: DictionarySyncState) -> Int {
        DictionarySyncMerge.removals(local: local, merged: merged).count
    }
}
