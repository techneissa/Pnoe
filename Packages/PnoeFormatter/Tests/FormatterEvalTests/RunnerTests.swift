import FormatterCore
import Foundation
import Testing
@testable import FormatterEvalKit

@Suite("Runner and report")
struct RunnerTests {
    let promptBuilder = try! PromptBuilder.bundled()

    static func sample(_ ids: [String]) -> [EvalCase] { ids.map(Fixtures.testCase) }

    /// Answers each request with the matching case's expected text, markers restored by the harness.
    static func echoRuntime(for cases: [EvalCase], mutate: @escaping @Sendable (String) -> String = { $0 }) -> FakeRuntime {
        let table = Dictionary(uniqueKeysWithValues: cases.map { testCase -> (String, String) in
            let protected = TokenProtector.protect(FillerCleaner.clean(testCase.raw, context: testCase.context))
            return (protected.text, mutate(Markerizer.markerize(testCase.expected, protected: protected)))
        })
        return FakeRuntime { request in
            let content = request.suffix.last?.content ?? ""
            let transcript = table.first { content.contains(jsonEscaped($0.key)) }?.value ?? ""
            return GenerationResult(text: transcript, stopReason: .eos, promptTokens: 12, generatedTokens: 8)
        }
    }

    @Test func runsEveryCaseThroughThePipeline() async {
        let cases = Self.sample(["r1-a1", "r1-a6", "r1-n1", "r1-c5"])
        let results = await EvalRunner.run(cases: cases, runtime: Self.echoRuntime(for: cases), promptBuilder: promptBuilder)
        #expect(results.map(\.id) == cases.map(\.id))
        for result in results { #expect(result.outcome == "formatted", "\(result.id): \(result.reason ?? "")") }
        #expect(results.allSatisfy { $0.pipeline.looseMatch && $0.pipeline.protectedSurvived != false })
        // A live run carries the model's own text and score beside the pipeline's.
        #expect(results.allSatisfy { $0.modelText != nil && $0.modelAlone != nil })
    }

    @Test func theGuardsTurnABadModelAnswerIntoRaw() async {
        let cases = Self.sample(["r1-a6"])
        let runtime = Self.echoRuntime(for: cases) { $0.replacingOccurrences(of: "⟦1⟧", with: "feature/slash-settings") }
        let results = await EvalRunner.run(cases: cases, runtime: runtime, promptBuilder: promptBuilder)
        let result = results[0]
        #expect(result.outcome == "raw")
        #expect(result.reason == "placeholder_lost")
        // The model alone changed the branch; the pipeline pasted the raw take with it intact.
        #expect(result.modelAlone?.protectedSurvived == false)
        #expect(result.pipeline.protectedSurvived == true)
    }

    @Test func summaryCountsFallbacksByReason() async {
        let cases = Self.sample(["r1-a1", "r1-a6", "r1-p1"])
        let runtime = Self.echoRuntime(for: cases) { $0.replacingOccurrences(of: "feature/settings", with: "feature/other") }
        var results = await EvalRunner.run(cases: cases, runtime: runtime, promptBuilder: promptBuilder)
        results[0].reason = "timeout"
        let summary = RunSummary(run: "r", backend: "ollama", model: "m", results: results)
        #expect(summary.cases == 3)
        #expect(summary.fallback.byReason["timeout"] == 1)
        // p1 is "john at example dot com": too short for the model, skipped and not counted as a fallback.
        #expect(summary.fallback.skipped == 1)
        #expect(summary.fallback.considered == 2)
        #expect(summary.byContext["agent"]?.cases == 2)
    }

    @Test func reportRoundTripsAndNamesTheFiles() throws {
        let result = CaseResult(
            id: "x", context: .chat, kind: .format, outcome: "formatted", reason: nil, finalText: "Hi.", modelText: "Hi.",
            pipeline: Scorer.score(EvalCase(id: "x", context: .chat, raw: "hi", expected: "Hi."), output: "Hi."), modelAlone: nil, seconds: 0.5
        )
        let file = RunFile(summary: RunSummary(run: "unit", backend: "ollama", model: "m:1", results: [result]), gate: nil, results: [result])
        let directory = FileManager.default.temporaryDirectory.appending(path: "pnoe-eval-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let written = try Report.write(file, to: directory)
        #expect(written.json.lastPathComponent == "unit.json")
        #expect(written.markdown.lastPathComponent == "unit.md")
        let decoded = try JSONDecoder().decode(RunFile.self, from: Data(contentsOf: written.json))
        #expect(decoded.results == [result])
        let markdown = try String(contentsOf: written.markdown, encoding: .utf8)
        #expect(markdown.contains("Full pipeline"))
        #expect(markdown.contains("Fallback rate"))
    }

    @Test func gateTextStatesPassAndMiss() async {
        let gate = await ReplayGate.evaluate(cases: Fixtures.cases, replay: Fixtures.replay, promptBuilder: promptBuilder)
        let results = await EvalRunner.runOracle(cases: Array(Fixtures.cases.prefix(5)), promptBuilder: promptBuilder)
        let file = RunFile(summary: RunSummary(run: "replay", backend: "replay", model: nil, results: results), gate: gate, results: results)
        let text = Report.markdownText(file)
        #expect(text.contains("## Tier 1 gate: \(gate.pass ? "PASS" : "MISS")"))
        #expect(text.contains("Good outputs wrongly rejected"))
        #expect(text.contains("Ideal answers through the guards"))
    }
}

private func jsonEscaped(_ text: String) -> String {
    let data = (try? JSONEncoder().encode(text)) ?? Data()
    let encoded = String(decoding: data, as: UTF8.self)
    return String(encoded.dropFirst().dropLast())
}
