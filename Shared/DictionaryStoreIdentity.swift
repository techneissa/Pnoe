import Foundation

/// A token that belongs to one dictionary store file and changes when that store is deleted and made
/// again or restored from a backup. The sync's remembered state is only trusted for the token it was made
/// for; a state that outlived its store would otherwise read as "the user deleted everything".
///
/// The token lives in a small file next to the store, together with what identifies the store file (its
/// creation date and file number). If the store file is not the one the token was written for, the token
/// is replaced.
enum DictionaryStoreIdentity {
    private struct Record: Codable, Equatable {
        var token: String
        var fileNumber: UInt64?
        var created: Date?
    }

    /// The token for the store at `storeURL`. `tokenURL` is the side file; both are created as needed.
    static func token(storeURL: URL, tokenURL: URL) -> String {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: storeURL.path)) ?? [:]
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let created = attributes[.creationDate] as? Date

        if let data = try? Data(contentsOf: tokenURL),
            let record = try? JSONDecoder().decode(Record.self, from: data),
            record.fileNumber == fileNumber,
            record.created == created
        {
            return record.token
        }
        let record = Record(token: UUID().uuidString, fileNumber: fileNumber, created: created)
        if let data = try? JSONEncoder().encode(record) {
            try? FileManager.default.createDirectory(
                at: tokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: tokenURL, options: .atomic)
        }
        return record.token
    }
}
