import Foundation

struct DictionarySyncReport: Equatable, Sendable {
    let syncedAt: Date
    /// The sync file was written (it was missing, or this Mac had something the file lacked).
    let wroteFile: Bool
}

/// One sync pass: capture this Mac's changes, merge them with the file under one file coordination,
/// write the file if it changed, then apply what came from the other Macs to the store.
///
/// Passes must not overlap; `DictionarySyncController` runs one at a time. A pass that fails leaves the
/// remembered state alone, so the next one starts from the same place.
actor DictionarySyncEngine {
    private let store: DictionarySyncStore
    private let drive: any DictionarySyncDrive
    private let stateFile: DictionarySyncLocalStateFile
    private let clock: @Sendable () -> Date

    init(
        store: DictionarySyncStore,
        drive: any DictionarySyncDrive,
        stateFile: DictionarySyncLocalStateFile,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.drive = drive
        self.stateFile = stateFile
        self.clock = clock
    }

    /// Stamps this Mac's changes with the time they were noticed and remembers them, without touching the
    /// drive. A pass that can't reach the drive still does this, so an edit made while iCloud Drive was
    /// off keeps the time it was made and not the time the drive came back.
    func recordLocalChanges() async throws {
        _ = try await captureLocalChanges()
    }

    func run() async throws -> DictionarySyncReport {
        let (deviceID, local, now) = try await captureLocalChanges()

        let drive = self.drive
        let (merged, wroteFile) = try await Task.detached(priority: .utility) {
            var merged = DictionarySyncState()
            var wrote = false
            try drive.exchange { existing in
                var remote = DictionarySyncState()
                if let existing {
                    // A file this version can't read is never overwritten: throw before any write.
                    guard let decoded = try? DictionarySyncFormat.decode(existing) else {
                        throw DictionarySyncError.unreadableFile
                    }
                    remote = decoded.state
                }
                merged = DictionarySyncMerge.merge(local, remote, now: now)
                guard existing == nil || merged != remote else { return nil }
                wrote = true
                return try DictionarySyncFormat.encode(merged, deviceID: deviceID, now: now)
            }
            return (merged, wrote)
        }.value

        do {
            try await store.apply(merged: merged, local: local)
        } catch {
            throw DictionarySyncError.storeFailed
        }
        try? stateFile.save(.init(deviceID: deviceID, state: merged), now: now)
        return DictionarySyncReport(syncedAt: now, wroteFile: wroteFile)
    }

    private func captureLocalChanges() async throws -> (
        deviceID: String, local: DictionarySyncState, now: Date
    ) {
        let remembered = stateFile.load()
        let deviceID = remembered?.deviceID ?? UUID().uuidString
        let now = DictionarySyncMerge.floored(clock())
        let local: DictionarySyncState
        do {
            local = try await store.capture(last: remembered?.state ?? DictionarySyncState(), now: now)
        } catch {
            throw DictionarySyncError.storeFailed
        }
        try? stateFile.save(.init(deviceID: deviceID, state: local), now: now)
        return (deviceID, local, now)
    }
}
