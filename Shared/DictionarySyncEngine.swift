import Foundation

typealias DictionarySyncRemoval = DictionarySyncMerge.Removal
typealias DictionarySyncConflict = DictionarySyncMerge.Conflict

/// What a pass would do to this Mac's dictionary, worked out without changing anything.
struct DictionarySyncPlan: Equatable, Sendable {
    var added: Int
    var updated: Int
    /// Entries this Mac would lose: deleted on another Mac, or left out by the lifetime rule.
    var removals: [DictionarySyncRemoval]
    /// Entries changed on both Macs since this Mac's last pass, or edited on one and deleted on the other.
    var conflicts: [DictionarySyncConflict]

    var removalKeys: Set<DictionarySyncKey> { Set(removals.map(\.key)) }
    var conflictKeys: Set<DictionarySyncKey> { Set(conflicts.map(\.key)) }
    /// Everything the user is asked about.
    var reviewedKeys: Set<DictionarySyncKey> { removalKeys.union(conflictKeys) }
    var needsReview: Bool { !removals.isEmpty || !conflicts.isEmpty }
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

/// One choice for every conflict.
enum DictionarySyncConflictChoice: Sendable {
    /// This Mac's version (or its deletion) goes into the file and wins.
    case thisMac
    /// The file's version (or deletion) wins here.
    case otherMac
}

/// The user's answers to the question. The defaults are the ones that lose nothing.
struct DictionarySyncAnswer: Equatable, Sendable {
    var removals: DictionarySyncDeletionChoice = .keep
    var conflicts: DictionarySyncConflictChoice = .thisMac
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
        let combined = try Self.combine(contents, with: context, keepingRemovals: [], conflictChoice: .thisMac)
        return DictionarySyncPlan(
            added: Self.addedCount(local: context.local, merged: combined.merged),
            updated: Self.updatedCount(local: context.local, merged: combined.merged),
            removals: combined.removals, conflicts: combined.conflicts)
    }

    /// - Parameter reviewed: the entries the user was asked about (`plan.reviewedKeys`). If the pass would
    ///   remove or settle anything else, it stops with `changedDuringReview` and nothing changes.
    func commit(
        answer: DictionarySyncAnswer,
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
                var combined = try Self.combine(
                    contents, with: context, keepingRemovals: [], conflictChoice: answer.conflicts)
                let removalKeys = Set(combined.removals.map(\.key))
                let asked = removalKeys.union(combined.conflicts.map(\.key))
                guard asked.isSubset(of: reviewed) else { throw DictionarySyncError.changedDuringReview }
                if answer.removals == .keep, !removalKeys.isEmpty {
                    combined = try Self.combine(
                        contents, with: context, keepingRemovals: removalKeys, conflictChoice: answer.conflicts)
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
            removed: combined.removals.count,
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
        /// What the last pass left; `nil` in a first merge.
        let last: DictionarySyncState?
    }

    private struct Combined: Sendable {
        var merged: DictionarySyncState
        var removals: [DictionarySyncRemoval]
        var conflicts: [DictionarySyncConflict]
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
            lastSyncAt: isFirstMerge ? nil : remembered?.lastSyncAt, isFirstMerge: isFirstMerge,
            last: isFirstMerge ? nil : remembered?.state)
    }

    private func readDrive() async throws -> DictionarySyncDriveContents {
        let drive = self.drive
        return try await Task.detached(priority: .utility) { try drive.read() }.value
    }

    /// Merges the file and its conflict copies with this Mac's state. A file this version can't read
    /// stops the pass here, before anything is written; a conflict copy it can't read is left alone.
    private static func combine(
        _ contents: DictionarySyncDriveContents, with context: PassContext,
        keepingRemovals: Set<DictionarySyncKey>, conflictChoice: DictionarySyncConflictChoice
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

        let conflicts = DictionarySyncMerge.conflicts(local: context.local, remote: remote, last: context.last)
        let conflictKeys = Set(conflicts.map(\.key))
        let prepared = DictionarySyncMerge.prepared(
            local: context.local, remote: remote, now: context.now, lastSyncAt: context.lastSyncAt,
            isFirstMerge: context.isFirstMerge,
            keeping: keepingRemovals.union(conflictChoice == .thisMac ? conflictKeys : []),
            yielding: conflictChoice == .otherMac ? conflictKeys : [])
        let merged = DictionarySyncMerge.merge(prepared, remote, now: context.now)
        let removals = DictionarySyncMerge.removals(
            local: context.local, merged: merged, remote: remote, excluding: conflictKeys)
        return Combined(
            merged: merged, removals: removals, conflicts: conflicts, consumed: consumed,
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
}
