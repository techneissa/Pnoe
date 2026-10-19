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
    var created: Date

    enum CodingKeys: String, CodingKey {
        case id, context, raw, expected, kind, tags, workflow, output, created
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
        template: LocalWorkflowTemplate?, id: String = idPrefix + UUID().uuidString.prefix(8).lowercased(),
        now: Date = Date()
    ) -> PlaygroundExample {
        PlaygroundExample(
            id: id, raw: raw, expected: expected, tags: [personalTag, tag(for: template)],
            workflow: workflowName, output: output, created: now)
    }
}

/// The examples file: JSONL in Application Support, one pair per line, never uploaded. A line that does not
/// parse is left in the file when others change, and counted so the list can say so.
struct PlaygroundExampleStore {
    struct Loaded: Equatable {
        var examples: [PlaygroundExample]
        /// Lines that are not a valid example. They stay in the file.
        var unreadableLines: Int
    }

    enum StoreError: Error, Equatable {
        case notFound(String)
        case emptyText
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

    func load() -> Loaded {
        let lines = readLines()
        let parsed = lines.map(Self.decode)
        return Loaded(examples: parsed.compactMap { $0 }, unreadableLines: parsed.filter { $0 == nil }.count)
    }

    /// Adds a pair at the end. Text that is empty after trimming is refused.
    func append(_ example: PlaygroundExample) throws {
        guard
            !example.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !example.expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw StoreError.emptyText }
        var lines = readLines()
        lines.append(try Self.encode(example))
        try write(lines)
    }

    /// Replaces the expected text of a saved pair.
    func updateExpected(id: String, to expected: String) throws {
        guard !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.emptyText }
        var found = false
        var lines = readLines()
        for index in lines.indices {
            guard var example = Self.decode(lines[index]), example.id == id else { continue }
            example.expected = expected
            lines[index] = try Self.encode(example)
            found = true
        }
        guard found else { throw StoreError.notFound(id) }
        try write(lines)
    }

    func delete(id: String) throws {
        let lines = readLines()
        let kept = lines.filter { Self.decode($0)?.id != id }
        guard kept.count != lines.count else { throw StoreError.notFound(id) }
        try write(kept)
    }

    /// Writes the readable pairs to `destination` as a test set file, one per line. Unreadable lines are
    /// left out. Returns how many pairs were written.
    @discardableResult
    func export(to destination: URL) throws -> Int {
        let lines = readLines().filter { Self.decode($0) != nil }
        let text = lines.map { $0 + "\n" }.joined()
        try text.write(to: destination, atomically: true, encoding: .utf8)
        return lines.count
    }

    // MARK: - File

    private func readLines() -> [String] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func write(_ lines: [String]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.map { $0 + "\n" }.joined()
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private static func encode(_ example: PlaygroundExample) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(example), as: UTF8.self)
    }

    private static func decode(_ line: String) -> PlaygroundExample? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let example = try? decoder.decode(PlaygroundExample.self, from: Data(line.utf8)) else { return nil }
        return example
    }
}

/// The sentence the Playground shows when Cleaned Text pasted the plain transcript instead of the model's
/// text. The input is a `FallbackReason` code.
enum PlaygroundFallbackText {
    static func sentence(forCode code: String) -> String {
        guard let reason = FallbackReason(rawValue: code) else {
            return "The checks rejected the model's text, so the plain transcript was used."
        }
        switch reason {
        case .tooShort: return "The text is too short to need the model, so only the code cleanup ran."
        case .disabled, .contextOff: return "Cleanup is switched off for this text, so only the code cleanup ran."
        case .emptyInput: return "There was no text to clean."
        case .modelNotReady, .modelLoading: return "The model was not ready, so the plain transcript was used."
        case .timeout: return "The model took too long, so the plain transcript was used."
        case .runtimeCrashed, .runtimeError: return "The model failed to answer, so the plain transcript was used."
        case .cancelled: return "The run was cancelled, so the plain transcript was used."
        case .truncated: return "The model's reply was cut off, so the plain transcript was used."
        case .wrapper, .empty:
            return "The model's reply was empty or wrapped in extra text, so the plain transcript was used."
        case .placeholderLost, .placeholderDup, .placeholderOrder, .placeholderUnknown:
            return "The model changed a protected name, path or number, so the plain transcript was used."
        case .length, .newWords, .dropped, .droppedSpan, .meta:
            return "The model changed your words, so the plain transcript was used."
        case .newNumber, .inventedCurrency:
            return "The model added a number or currency you did not say, so the plain transcript was used."
        case .questionLost, .statementToQuestion:
            return "The model changed a question into a statement or the other way round, so the plain transcript was used."
        }
    }
}

extension LocalWorkflowTemplate {
    /// The template whose seeded prompt has this id, or nil for a prompt that is not a Pnoe template.
    static func template(forPromptId id: UUID?) -> LocalWorkflowTemplate? {
        guard let id else { return nil }
        return allCases.first { $0.promptId == id }
    }
}
