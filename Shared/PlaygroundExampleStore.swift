import FormatterCore
import Foundation

/// One saved Playground pair. A line of the examples file is a case of the eval harness's test set
/// (`Packages/PnoeFormatter/Eval/testset.jsonl`), plus a few extra keys the harness ignores.
struct PlaygroundExample: Codable, Identifiable, Equatable {
    var id: String
    /// Cleaned Text always runs in the plain context.
    var context = "plain"
    /// What went in: the typed, pasted or dictated text.
    var raw: String
    /// What the workflow should have produced, the speaker's own take.
    var expected: String
    var protectedSpans: [String] = []
    var kind = "format"
    /// `personal`, and `workflow:<template>` (`workflow:custom` for a workflow without a Pnoe template).
    var tags: [String]
    var mustContain: [[String]] = []
    var mustNot: [String] = []
    // Not part of the test set format; the harness skips them.
    var workflow: String
    /// What the workflow actually wrote, so a pair saved "as is" can be told from an edited one.
    var output: String
    /// The model the pair was run on, when it was run in the Playground with one.
    var model: String?
    var created: Date
    /// The line of the file it was read from (0 for the first). Not saved.
    var line = 0

    /// A key for lists: two pairs may share an id if a file was edited by hand.
    var listID: String { "\(line)-\(id)" }

    enum CodingKeys: String, CodingKey {
        case id, context, raw, expected, kind, tags, workflow, output, model, created
        case protectedSpans = "protected"
        case mustContain = "must_contain"
        case mustNot = "must_not"
    }

    /// True when the speaker changed the workflow's result before saving.
    var wasEdited: Bool { expected != output }

    /// The tag that names the workflow the pair came from.
    var workflowTag: String? { tags.first { $0.hasPrefix(Self.workflowTagPrefix) } }

    static let personalTag = "personal"
    static let workflowTagPrefix = "workflow:"
    static let idPrefix = "mine-"

    static func tag(for template: LocalWorkflowTemplate?) -> String {
        workflowTagPrefix + (template?.rawValue ?? "custom")
    }

    static func make(
        raw: String, output: String, expected: String, workflowName: String,
        template: LocalWorkflowTemplate?, model: String? = nil, id: String = idPrefix + UUID().uuidString.prefix(8).lowercased(),
        now: Date = Date()
    ) -> PlaygroundExample {
        PlaygroundExample(
            id: id, raw: raw, expected: expected, tags: [personalTag, tag(for: template)],
            workflow: workflowName, output: output, model: model, created: now)
    }
}

/// The examples file: JSONL in Application Support, one pair per line, never uploaded. A line that does not
/// parse (bad JSON, missing keys, bytes that are not UTF-8) is left in the file byte for byte when others
/// change, and counted so the list can say so. Nothing is ever written after a failed read: only a missing
/// file counts as empty.
struct PlaygroundExampleStore {
    struct Loaded: Equatable {
        var examples: [PlaygroundExample]
        /// Lines that are not a valid example. They stay in the file.
        var unreadableLines: Int
    }

    enum StoreError: Error, Equatable, LocalizedError {
        case notFound(String)
        case emptyText

        var errorDescription: String? {
            switch self {
            case .notFound: "That example is not in the file any more."
            case .emptyText: "The text is empty."
            }
        }
    }

    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.techneissa.Pnoe", isDirectory: true)
            .appendingPathComponent("playground-examples.jsonl")
    }

    static func standard() -> PlaygroundExampleStore { PlaygroundExampleStore(fileURL: defaultFileURL) }

    /// Throws when the file exists and cannot be read.
    func load() throws -> Loaded {
        let parsed = try readLines().enumerated().map { index, line -> PlaygroundExample? in
            guard var example = Self.decode(line) else { return nil }
            example.line = index
            return example
        }
        return Loaded(examples: parsed.compactMap { $0 }, unreadableLines: parsed.filter { $0 == nil }.count)
    }

    /// Adds a pair at the end. Text that is empty after trimming is refused.
    func append(_ example: PlaygroundExample) throws {
        guard
            !example.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !example.expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw StoreError.emptyText }
        var lines = try readLines()
        lines.append(try Self.encode(example))
        try write(lines)
    }

    /// Replaces the expected text of the pair on that line of the file (and with that id).
    func updateExpected(of example: PlaygroundExample, to expected: String) throws {
        guard !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.emptyText }
        var lines = try readLines()
        guard lines.indices.contains(example.line), var stored = Self.decode(lines[example.line]), stored.id == example.id
        else { throw StoreError.notFound(example.id) }
        stored.expected = expected
        lines[example.line] = try Self.encode(stored)
        try write(lines)
    }

    /// Removes the one pair on that line of the file (and with that id); a second pair with the same id stays.
    func delete(_ example: PlaygroundExample) throws {
        var lines = try readLines()
        guard lines.indices.contains(example.line), Self.decode(lines[example.line])?.id == example.id
        else { throw StoreError.notFound(example.id) }
        lines.remove(at: example.line)
        try write(lines)
    }

    /// Writes the readable pairs to `destination` as a test set file, one per line. Unreadable lines are
    /// left out. Returns how many pairs were written.
    @discardableResult
    func export(to destination: URL) throws -> Int {
        let lines = try readLines().filter { Self.decode($0) != nil }
        try join(lines).write(to: destination, options: .atomic)
        return lines.count
    }

    // MARK: - File

    /// Every non-empty line as the bytes in the file. A missing file is empty; any other read error throws.
    private func readLines() throws -> [Data] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        }
        return data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).map { Data($0) }
    }

    private func write(_ lines: [Data]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try join(lines).write(to: fileURL, options: .atomic)
    }

    private func join(_ lines: [Data]) -> Data {
        lines.reduce(into: Data()) { result, line in
            result.append(line)
            result.append(UInt8(ascii: "\n"))
        }
    }

    private static func encode(_ example: PlaygroundExample) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(example)
    }

    private static func decode(_ line: Data) -> PlaygroundExample? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PlaygroundExample.self, from: line)
    }
}

/// The sentence the Playground shows when Cleaned Text did not paste the model's text. The input is a
/// `FallbackReason` code.
enum PlaygroundFallbackText {
    /// Said after the reason: what was pasted instead.
    static let usedPhrase = "Pnoe's own cleanup was used."

    /// Why the model's text was not used, in a few words.
    static func sentence(forCode code: String) -> String {
        guard let reason = FallbackReason(rawValue: code) else { return "The model's text was rejected." }
        switch reason {
        case .tooShort: return "The text is too short for the model."
        case .disabled, .contextOff: return "Cleanup is switched off for this text."
        case .emptyInput: return "There was no text to clean."
        case .modelNotReady, .modelLoading: return "The model was not ready."
        case .timeout: return "The model took too long."
        case .runtimeCrashed, .runtimeError: return "The model failed to answer."
        case .cancelled: return "The run was cancelled."
        case .truncated: return "The model's reply was cut off."
        case .wrapper, .empty: return "The model's reply was empty or wrapped in extra text."
        case .placeholderLost, .placeholderDup, .placeholderOrder, .placeholderUnknown:
            return "The model changed a name, path or number."
        case .length, .newWords, .dropped, .droppedSpan, .meta: return "The model changed your wording."
        case .newNumber, .inventedCurrency: return "The model added a number you didn't say."
        case .questionLost, .statementToQuestion: return "The model turned a question into a statement, or the reverse."
        }
    }

    /// The reason and what was pasted instead.
    static func fullSentence(forCode code: String) -> String {
        FallbackReason(rawValue: code) == .emptyInput ? sentence(forCode: code) : sentence(forCode: code) + " " + usedPhrase
    }
}

extension LocalWorkflowTemplate {
    /// The template whose seeded prompt has this id, or nil for a prompt that is not a Pnoe template.
    static func template(forPromptId id: UUID?) -> LocalWorkflowTemplate? {
        guard let id else { return nil }
        return allCases.first { $0.promptId == id }
    }
}
