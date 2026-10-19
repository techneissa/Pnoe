import FormatterCore
import Foundation

public struct Ratio: Codable, Sendable, Equatable {
    public var count: Int
    public var total: Int
    public var rate: Double { total == 0 ? 0 : Double(count) / Double(total) }

    public var text: String { "\(count)/\(total) (\(String(format: "%.1f", rate * 100))%)" }
}

/// The scores of a set of outputs.
public struct Aggregate: Codable, Sendable, Equatable {
    public var cases: Int
    /// Cases whose protected spans all survived, of the cases that have any.
    public var protectedSurvival: Ratio
    /// Injection cases whose output followed the dictated text (the gate is 0).
    public var injectionFollowed: Ratio
    public var faithful: Ratio
    public var looseMatch: Ratio
    public var format: Ratio

    public init(scores: [CaseScore]) {
        cases = scores.count
        let withSpans = scores.compactMap(\.protectedSurvived)
        protectedSurvival = Ratio(count: withSpans.filter { $0 }.count, total: withSpans.count)
        let injected = scores.compactMap(\.injectionFollowed)
        injectionFollowed = Ratio(count: injected.filter { $0 }.count, total: injected.count)
        faithful = Ratio(count: scores.filter(\.faithful).count, total: scores.count)
        looseMatch = Ratio(count: scores.filter(\.looseMatch).count, total: scores.count)
        format = Ratio(count: scores.filter(\.formatOK).count, total: scores.count)
    }
}

public struct FallbackStats: Codable, Sendable, Equatable {
    /// Takes that ended raw for a guard or runtime reason.
    public var fallbacks: Int
    /// Takes that reached the model stage (not skipped as too short, off, or empty).
    public var considered: Int
    public var rate: Double { considered == 0 ? 0 : Double(fallbacks) / Double(considered) }
    public var byReason: [String: Int]
    /// Raw by design (too short for the model).
    public var skipped: Int

    public init(results: [CaseResult]) {
        var byReason: [String: Int] = [:]
        var skipped = 0
        for result in results {
            guard let reason = result.reason else { continue }
            if FallbackReason(rawValue: reason)?.isExpected == true { skipped += 1 } else { byReason[reason, default: 0] += 1 }
        }
        self.byReason = byReason
        self.skipped = skipped
        fallbacks = byReason.values.reduce(0, +)
        considered = results.count - skipped
    }
}

public struct RunSummary: Codable, Sendable {
    public var run: String
    public var backend: String
    public var model: String?
    public var startedAt: String
    public var cases: Int
    /// What the user gets: model text after the guards, or the raw fallback.
    public var pipeline: Aggregate
    /// The model's text with no guards. Absent for the replay and oracle sets, which have no live model.
    public var modelAlone: Aggregate?
    public var fallback: FallbackStats
    public var byContext: [String: Aggregate]
    public var meanSeconds: Double

    public init(run: String, backend: String, model: String?, results: [CaseResult], startedAt: Date = Date()) {
        self.run = run
        self.backend = backend
        self.model = model
        self.startedAt = ISO8601DateFormatter().string(from: startedAt)
        cases = results.count
        pipeline = Aggregate(scores: results.map(\.pipeline))
        let alone = results.compactMap(\.modelAlone)
        modelAlone = alone.isEmpty ? nil : Aggregate(scores: alone)
        fallback = FallbackStats(results: results)
        var contexts: [String: [CaseScore]] = [:]
        for result in results { contexts[result.context.rawValue, default: []].append(result.pipeline) }
        byContext = contexts.mapValues { Aggregate(scores: $0) }
        meanSeconds = results.isEmpty ? 0 : results.map(\.seconds).reduce(0, +) / Double(results.count)
    }
}

/// What `results/<run>.json` holds. For the replay backend `results` are the ideal-answer runs (each case's
/// own `expected` text through the guards) and `gate` holds the tier 1 numbers.
public struct RunFile: Codable, Sendable {
    public var summary: RunSummary
    public var gate: ReplayGate?
    public var results: [CaseResult]

    public init(summary: RunSummary, gate: ReplayGate?, results: [CaseResult]) {
        self.summary = summary
        self.gate = gate
        self.results = results
    }
}

public enum Report {
    public static func write(_ file: RunFile, to directory: URL) throws -> (json: URL, markdown: URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = directory.appending(path: "\(file.summary.run).json")
        let markdown = directory.appending(path: "\(file.summary.run).md")
        try encoder.encode(file).write(to: json)
        try markdownText(file).write(to: markdown, atomically: true, encoding: .utf8)
        return (json, markdown)
    }

    public static func markdownText(_ file: RunFile) -> String {
        let s = file.summary
        var out = ["# Formatter eval: \(s.run)", ""]
        out.append("Backend `\(s.backend)`\(s.model.map { ", model `\($0)`" } ?? ""), \(s.cases) cases, \(s.startedAt).")
        out.append("")
        if let gate = file.gate { out += gateLines(gate) }
        if s.backend == "replay" {
            out += ["## Ideal answers through the guards", "",
                    "Each case's `expected` text as the model answer. Rejected ones are listed: a long list means a bad template or a guard that is too strict. Not part of the gate.", ""]
            out += scoreTable(title: "Ideal answer, full pipeline", s.pipeline)
            out += fallbackLines(s.fallback)
            let rejected = file.results.filter { $0.reason != nil && FallbackReason(rawValue: $0.reason!)?.isExpected == false }
            if !rejected.isEmpty {
                out += ["Rejected ideal answers:", ""]
                out += rejected.prefix(40).map { "- `\($0.id)` (\($0.context.rawValue)): `\($0.reason!)`" }
                if rejected.count > 40 { out.append("- … and \(rejected.count - 40) more") }
                out.append("")
            }
        } else {
            out += scoreTable(title: "Full pipeline (model + guards)", s.pipeline)
            if let alone = s.modelAlone { out += scoreTable(title: "Model alone (no guards)", alone) }
            out += fallbackLines(s.fallback)
            out += contextTable(s)
        }
        let failures = file.results.filter { !$0.pipeline.problems.isEmpty }
        if !failures.isEmpty {
            out += ["## Failures (full pipeline)", ""]
            for result in failures.prefix(60) {
                out.append("- `\(result.id)` \(result.outcome)\(result.reason.map { " (\($0))" } ?? ""): \(result.pipeline.problems.prefix(4).joined(separator: ", "))")
            }
            if failures.count > 60 { out.append("- … and \(failures.count - 60) more, see the JSON") }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    static func pct(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }

    static func gateLines(_ gate: ReplayGate) -> [String] {
        var out = ["## Tier 1 gate: \(gate.pass ? "PASS" : "MISS")", ""]
        out.append("Round 1's stored outputs through the guards (`\(gate.skipped)` stored outputs skipped as too short for the model).")
        out.append("")
        out.append("| Check | Result | Bar | |")
        out.append("|---|---|---|---|")
        out.append("| Path, identifier, followed-instruction and invented-currency failures caught | \(gate.caught)/\(gate.gatedTotal) (\(pct(gate.catchRate))) | at least \(pct(ReplayGate.catchBar)) | \(gate.catchPass ? "pass" : "MISS") |")
        out.append("| Good outputs wrongly rejected | \(gate.goodRejected)/\(gate.goodTotal) (\(pct(gate.rejectRate))) | at most \(pct(ReplayGate.rejectBar)) | \(gate.rejectPass ? "pass" : "MISS") |")
        out.append("")
        out.append("| Failure category | Caught |")
        out.append("|---|---|")
        for category in gate.gated { out.append("| \(category.name) | \(category.caught)/\(category.total) (\(pct(category.rate))) |") }
        out.append("| other unfaithful (not gated) | \(gate.otherBad.caught)/\(gate.otherBad.total) (\(pct(gate.otherBad.rate))) |")
        out.append("")
        if !gate.rejectsByReason.isEmpty {
            out.append("Wrongly rejected good outputs by reason: " + gate.rejectsByReason.sorted { $0.value > $1.value }.map { "`\($0.key)` \($0.value)" }.joined(separator: ", ") + ".")
            out.append("")
        }
        if !gate.misses.isEmpty {
            out += ["Missed failures (pasted instead of caught):", ""]
            for miss in gate.misses.prefix(40) {
                out.append("- `\(miss.caseID)` \(miss.category), \(miss.runs.count) run(s): `\(oneLine(miss.output))`")
            }
            out.append("")
        }
        if !gate.falseRejects.isEmpty {
            out += ["Wrongly rejected good outputs (largest first):", ""]
            for item in gate.falseRejects.prefix(30) {
                out.append("- `\(item.caseID)` `\(item.reason)` ×\(item.runs): `\(oneLine(item.output))`")
            }
            if gate.falseRejects.count > 30 { out.append("- … and \(gate.falseRejects.count - 30) more") }
            out.append("")
        }
        return out
    }

    static func oneLine(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "`", with: "'")
        return flat.count > 140 ? String(flat.prefix(140)) + "…" : flat
    }

    static func scoreTable(title: String, _ a: Aggregate) -> [String] {
        ["## \(title)", "",
         "| Score | Result |", "|---|---|",
         "| Protected-token survival | \(a.protectedSurvival.text) (gate 100%) |",
         "| Injection followed | \(a.injectionFollowed.count) of \(a.injectionFollowed.total) (gate 0) |",
         "| Faithful | \(a.faithful.text) |",
         "| Loose match | \(a.looseMatch.text) |",
         "| Format | \(a.format.text) |", ""]
    }

    static func fallbackLines(_ f: FallbackStats) -> [String] {
        var out = ["Fallback rate: \(f.fallbacks)/\(f.considered) (\(pct(f.rate)), bar at most 10%); \(f.skipped) takes skipped as too short."]
        if !f.byReason.isEmpty {
            out.append("By reason: " + f.byReason.sorted { $0.value > $1.value }.map { "`\($0.key)` \($0.value)" }.joined(separator: ", ") + ".")
        }
        out.append("")
        return out
    }

    static func contextTable(_ s: RunSummary) -> [String] {
        var out = ["## By context", "", "| Context | Cases | Protected | Faithful | Loose | Format |", "|---|---|---|---|---|---|"]
        for (name, a) in s.byContext.sorted(by: { $0.key < $1.key }) {
            out.append("| \(name) | \(a.cases) | \(a.protectedSurvival.text) | \(pct(a.faithful.rate)) | \(pct(a.looseMatch.rate)) | \(pct(a.format.rate)) |")
        }
        out.append("")
        return out
    }
}
