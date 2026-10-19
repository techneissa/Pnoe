import FormatterCore
import Foundation

/// Tier 1: the guards over round 1's stored outputs. No model runs.
public struct ReplayGate: Codable, Sendable {
    public struct Category: Codable, Sendable, Equatable {
        public var name: String
        public var total: Int
        public var caught: Int
        public var rate: Double { total == 0 ? 1 : Double(caught) / Double(total) }
    }

    public struct Miss: Codable, Sendable, Equatable {
        public var caseID: String
        public var category: String
        public var runs: [String]
        public var output: String
        /// What the pipeline pasted instead of catching it.
        public var final: String
    }

    public struct FalseReject: Codable, Sendable, Equatable {
        public var caseID: String
        public var reason: String
        public var runs: Int
        public var output: String
    }

    public static let catchBar = 0.95
    public static let rejectBar = 0.08

    /// Path or identifier, followed instruction, invented currency: the failures the gate counts.
    public var gated: [Category]
    public var otherBad: Category
    public var caught: Int
    public var gatedTotal: Int
    public var goodTotal: Int
    public var goodRejected: Int
    public var rejectsByReason: [String: Int]
    /// Stored outputs the pipeline never judged because the take is too short for the model.
    public var skipped: Int
    public var misses: [Miss]
    public var falseRejects: [FalseReject]

    public var catchRate: Double { gatedTotal == 0 ? 1 : Double(caught) / Double(gatedTotal) }
    public var rejectRate: Double { goodTotal == 0 ? 0 : Double(goodRejected) / Double(goodTotal) }
    public var catchPass: Bool { catchRate >= Self.catchBar }
    public var rejectPass: Bool { rejectRate <= Self.rejectBar }
    public var pass: Bool { catchPass && rejectPass }

    static let gatedCategories: [String: String] = [
        "changed or lost a path, file name or identifier": "path or identifier",
        "followed or refused the dictated instruction/question": "followed instruction",
        "invented a currency symbol": "invented currency",
    ]

    public static func evaluate(cases: [EvalCase], replay: ReplayFile, promptBuilder: PromptBuilder) async -> ReplayGate {
        let byID = Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0) })
        var gated: [String: Category] = Dictionary(uniqueKeysWithValues: gatedCategories.values.map { ($0, Category(name: $0, total: 0, caught: 0)) })
        var other = Category(name: "other unfaithful", total: 0, caught: 0)
        var goodTotal = 0
        var goodRejected = 0
        var skipped = 0
        var reasons: [String: Int] = [:]
        var misses: [Miss] = []
        var falseRejects: [FalseReject] = []

        for entry in replay.entries where entry.label != .other {
            guard let testCase = byID["r1-" + entry.case] else { continue }
            let outcome = await replayOutcome(testCase, output: entry.output, promptBuilder: promptBuilder)
            // Too short for the model: the stored output never reaches the user, nothing to judge.
            if let reason = outcome.reason, reason.isExpected {
                skipped += entry.weight
                continue
            }
            let rejected = outcome.reason != nil
            switch entry.label {
            case .good:
                goodTotal += entry.weight
                if rejected {
                    goodRejected += entry.weight
                    reasons[outcome.reason!.rawValue, default: 0] += entry.weight
                    falseRejects.append(FalseReject(caseID: testCase.id, reason: outcome.reason!.rawValue, runs: entry.weight, output: entry.output))
                }
            case .bad:
                let name = gatedCategories[entry.category ?? ""]
                if let name {
                    gated[name]!.total += entry.weight
                    if rejected { gated[name]!.caught += entry.weight }
                } else {
                    other.total += entry.weight
                    if rejected { other.caught += entry.weight }
                }
                if !rejected, name != nil {
                    misses.append(Miss(caseID: testCase.id, category: name!, runs: entry.runs, output: entry.output, final: outcome.text))
                }
            case .other:
                break
            }
        }
        let categories = ["path or identifier", "followed instruction", "invented currency"].compactMap { gated[$0] }
        return ReplayGate(
            gated: categories,
            otherBad: other,
            caught: categories.reduce(0) { $0 + $1.caught },
            gatedTotal: categories.reduce(0) { $0 + $1.total },
            goodTotal: goodTotal,
            goodRejected: goodRejected,
            rejectsByReason: reasons,
            skipped: skipped,
            misses: misses,
            falseRejects: falseRejects.sorted { ($0.runs, $1.caseID) > ($1.runs, $0.caseID) }
        )
    }

    /// One stored output through the pipeline, as a marker-aware model would have answered.
    public static func replayOutcome(_ testCase: EvalCase, output: String, promptBuilder: PromptBuilder) async -> FormatterOutcome {
        let runtime = ReplayRuntime(output: ReplayAlignment.modelAnswer(forStored: output, testCase: testCase))
        return await FormatterPipeline(runtime: runtime, promptBuilder: promptBuilder).format(testCase.raw, context: testCase.context)
    }
}
