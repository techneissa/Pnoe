import Foundation

/// The maintainer's own saved pairs from the app's Workflow playground: a JSONL file in the format of
/// `testset.jsonl`, read as an extra test set. It is read leniently, because the app keeps a line it cannot
/// read in the file rather than dropping it.
public struct PersonalSet: Equatable, Sendable {
    /// The tag the app puts on a pair from Cleaned Text, the workflow the guards hold to the speaker's words.
    public static let cleanedTextTag = "workflow:cleanedText"
    public static let workflowTagPrefix = "workflow:"

    public var cases: [EvalCase]
    /// Lines that did not parse as a case, or repeated an earlier id.
    public var unreadableLines: Int
    /// Pairs from other workflows (rewriting templates, custom prompts). The scorers judge faithfulness to the words, so they are left out.
    public var skippedOtherWorkflows: Int

    public static func load(from url: URL) throws -> PersonalSet {
        parse(try String(contentsOf: url, encoding: .utf8))
    }

    public static func parse(_ text: String) -> PersonalSet {
        let decoder = JSONDecoder()
        var set = PersonalSet(cases: [], unreadableLines: 0, skippedOtherWorkflows: 0)
        var seen: Set<String> = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard
                let value = try? decoder.decode(EvalCase.self, from: Data(line.utf8)),
                seen.insert(value.id).inserted
            else {
                set.unreadableLines += 1
                continue
            }
            let workflowTags = value.tags.filter { $0.hasPrefix(workflowTagPrefix) }
            if workflowTags.contains(where: { $0 != cleanedTextTag }) {
                set.skippedOtherWorkflows += 1
                continue
            }
            set.cases.append(value)
        }
        return set
    }

    /// `base` followed by the personal cases. A personal id that is already in `base` is an error, like a
    /// duplicate inside one file.
    public static func merge(_ base: [EvalCase], with personal: [EvalCase]) throws -> [EvalCase] {
        var seen = Set(base.map(\.id))
        for value in personal where !seen.insert(value.id).inserted {
            throw TestSet.LoadError.duplicateID(value.id)
        }
        return base + personal
    }
}
