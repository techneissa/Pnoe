import FormatterCore
import Foundation

/// One line of `testset.jsonl`.
public struct EvalCase: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case format
        case cleanUnchanged = "clean_unchanged"
        case inject
        case question
        case shortSkip = "short_skip"
    }

    public var id: String
    public var context: FormatterContext
    /// What the speech engine emitted.
    public var raw: String
    /// The target text.
    public var expected: String
    /// Exact spans (paths, identifiers, addresses, versions, large numbers) that must survive verbatim.
    public var protectedSpans: [String]
    public var kind: Kind
    public var tags: [String]
    /// Every group needs at least one of its alternatives in the output (case-insensitive).
    public var mustContain: [[String]]
    public var mustNot: [String]
    /// The round 1 case this one is modelled on.
    public var seed: String?

    enum CodingKeys: String, CodingKey {
        case id, context, raw, expected, kind, tags, seed
        case protectedSpans = "protected"
        case mustContain = "must_contain"
        case mustNot = "must_not"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        context = try c.decode(FormatterContext.self, forKey: .context)
        raw = try c.decode(String.self, forKey: .raw)
        expected = try c.decode(String.self, forKey: .expected)
        protectedSpans = try c.decodeIfPresent([String].self, forKey: .protectedSpans) ?? []
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .format
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        mustContain = try c.decodeIfPresent([[String]].self, forKey: .mustContain) ?? []
        mustNot = try c.decodeIfPresent([String].self, forKey: .mustNot) ?? []
        seed = try c.decodeIfPresent(String.self, forKey: .seed)
    }

    public init(
        id: String, context: FormatterContext, raw: String, expected: String, protectedSpans: [String] = [],
        kind: Kind = .format, tags: [String] = [], mustContain: [[String]] = [], mustNot: [String] = [], seed: String? = nil
    ) {
        self.id = id
        self.context = context
        self.raw = raw
        self.expected = expected
        self.protectedSpans = protectedSpans
        self.kind = kind
        self.tags = tags
        self.mustContain = mustContain
        self.mustNot = mustNot
        self.seed = seed
    }
}

public enum TestSet {
    public enum LoadError: Error, CustomStringConvertible {
        case badLine(Int, String)
        case duplicateID(String)

        public var description: String {
            switch self {
            case .badLine(let n, let why): "testset line \(n): \(why)"
            case .duplicateID(let id): "duplicate case id \(id)"
            }
        }
    }

    public static func load(from url: URL) throws -> [EvalCase] {
        try parse(String(contentsOf: url, encoding: .utf8))
    }

    public static func parse(_ text: String) throws -> [EvalCase] {
        let decoder = JSONDecoder()
        var cases: [EvalCase] = []
        var seen: Set<String> = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            do {
                let value = try decoder.decode(EvalCase.self, from: Data(line.utf8))
                guard seen.insert(value.id).inserted else { throw LoadError.duplicateID(value.id) }
                cases.append(value)
            } catch let error as LoadError {
                throw error
            } catch {
                throw LoadError.badLine(index + 1, "\(error)")
            }
        }
        return cases
    }
}

/// Where the eval data lives: `Eval/` inside the package.
public struct EvalData: Sendable {
    public let directory: URL
    public var testsetURL: URL { directory.appending(path: "testset.jsonl") }
    public var round1OutputsURL: URL { directory.appending(path: "round1/outputs.json") }
    public var resultsDirectory: URL { directory.appending(path: "results") }

    public init(directory: URL) {
        self.directory = directory
    }

    /// `explicit` or `$PNOE_EVAL_DIR`, else the `Eval` folder found by walking up from the working directory
    /// (the repo root, the package or anywhere below them).
    public static func locate(explicit: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> EvalData {
        if let explicit { return try validated(URL(fileURLWithPath: explicit)) }
        if let fromEnv = environment["PNOE_EVAL_DIR"] { return try validated(URL(fileURLWithPath: fromEnv)) }
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while true {
            for candidate in ["Eval", "Packages/PnoeFormatter/Eval"] {
                let url = directory.appending(path: candidate)
                if FileManager.default.fileExists(atPath: url.appending(path: "testset.jsonl").path) { return EvalData(directory: url) }
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        throw LocateError.notFound
    }

    private static func validated(_ url: URL) throws -> EvalData {
        guard FileManager.default.fileExists(atPath: url.appending(path: "testset.jsonl").path) else { throw LocateError.missing(url.path) }
        return EvalData(directory: url)
    }

    public enum LocateError: Error, CustomStringConvertible {
        case notFound
        case missing(String)

        public var description: String {
            switch self {
            case .notFound: "Eval/testset.jsonl not found; run from the repo or pass --data-dir"
            case .missing(let path): "no testset.jsonl in \(path)"
            }
        }
    }
}
