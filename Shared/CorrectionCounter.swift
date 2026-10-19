import Foundation

/// Counts how often the same correction is repeated: the same heard text turned into the same
/// corrected text. Auto Learn saves the pair once the count reaches the user's threshold.
///
/// Counting is case-insensitive on the heard side ("Teh" and "teh" are one pair) and exact on the
/// corrected side, so "iPhone" and "Iphone" stay different corrections. The design follows the
/// occurrence counter in FluidVoice (see CREDITS.md); the code is Pnoe's own.
struct CorrectionCounter: Codable, Equatable, Sendable {
    struct Limits: Equatable, Sendable {
        /// Pairs kept at once. The pair seen longest ago is dropped first.
        var maximumPairs = 200
        /// A pair not repeated for this long starts again from zero.
        var staleAfter: TimeInterval = 30 * 24 * 60 * 60

        static let standard = Limits()
    }

    struct Pair: Codable, Equatable, Sendable {
        var heard: String
        var corrected: String
        var count: Int
        var lastSeen: Date
    }

    private(set) var pairs: [String: Pair] = [:]

    /// Adds one occurrence and returns the new count for the pair.
    @discardableResult
    mutating func record(
        heard: String,
        corrected: String,
        now: Date = Date(),
        limits: Limits = .standard
    ) -> Int {
        prune(now: now, limits: limits)
        let key = Self.key(heard: heard, corrected: corrected)
        var pair = pairs[key] ?? Pair(
            heard: Self.trimmed(heard),
            corrected: Self.trimmed(corrected),
            count: 0,
            lastSeen: now
        )
        pair.heard = Self.trimmed(heard)
        pair.count += 1
        pair.lastSeen = now
        pairs[key] = pair
        enforceCap(limits.maximumPairs)
        return pair.count
    }

    func count(heard: String, corrected: String) -> Int {
        pairs[Self.key(heard: heard, corrected: corrected)]?.count ?? 0
    }

    /// Forgets a pair, after it was saved or after the user undid the save.
    mutating func reset(heard: String, corrected: String) {
        pairs[Self.key(heard: heard, corrected: corrected)] = nil
    }

    /// Drops pairs that were not repeated within `limits.staleAfter`.
    mutating func prune(now: Date = Date(), limits: Limits = .standard) {
        pairs = pairs.filter { now.timeIntervalSince($0.value.lastSeen) <= limits.staleAfter }
    }

    private mutating func enforceCap(_ maximumPairs: Int) {
        guard pairs.count > maximumPairs else { return }
        let keep = pairs.sorted { $0.value.lastSeen > $1.value.lastSeen }.prefix(maximumPairs)
        pairs = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    static func key(heard: String, corrected: String) -> String {
        let heardKey = (trimmed(heard) as NSString).folding(options: .caseInsensitive, locale: nil)
        return heardKey + "\u{1F}" + trimmed(corrected)
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }
}

/// Keeps a `CorrectionCounter` on disk so counts survive a restart.
actor CorrectionCountStore {
    private let fileURL: URL
    private let limits: CorrectionCounter.Limits
    private var counter = CorrectionCounter()
    private var isLoaded = false

    init(fileURL: URL, limits: CorrectionCounter.Limits = .standard) {
        self.fileURL = fileURL
        self.limits = limits
    }

    /// The store Auto Learn uses, next to its other files in Application Support.
    static func standardFileURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.techneissa.Pnoe", isDirectory: true)
            .appendingPathComponent("auto-learn-correction-counts.json")
    }

    func record(heard: String, corrected: String, now: Date = Date()) throws -> Int {
        loadIfNeeded()
        let before = counter
        let count = counter.record(heard: heard, corrected: corrected, now: now, limits: limits)
        do { try save() } catch { counter = before; throw error }
        return count
    }

    func count(heard: String, corrected: String) -> Int {
        loadIfNeeded()
        return counter.count(heard: heard, corrected: corrected)
    }

    func reset(heard: String, corrected: String) throws {
        loadIfNeeded()
        let before = counter
        counter.reset(heard: heard, corrected: corrected)
        guard counter != before else { return }
        do { try save() } catch { counter = before; throw error }
    }

    /// A missing or unreadable file starts a fresh counter: losing counts only delays a save.
    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try? Data(contentsOf: fileURL),
            let stored = try? JSONDecoder().decode(CorrectionCounter.self, from: data)
        else { return }
        counter = stored
    }

    private func save() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(counter).write(to: fileURL, options: .atomic)
    }
}
