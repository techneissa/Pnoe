import FormatterCore
import Foundation

/// What one case produced.
public struct CaseResult: Codable, Sendable, Equatable {
    public var id: String
    public var context: FormatterContext
    public var kind: EvalCase.Kind
    /// `formatted` or `raw`.
    public var outcome: String
    public var reason: String?
    /// What the user would get: model output after the guards, or the code-cleaned take.
    public var finalText: String
    /// The model's own text with markers restored, before the guards. `nil` when no model ran.
    public var modelText: String?
    public var pipeline: CaseScore
    public var modelAlone: CaseScore?
    public var seconds: Double
}

/// Wraps a runtime and remembers the last answer, so the harness can score the model before the guards.
actor RecordingRuntime: FormatterRuntime {
    nonisolated let id: FormatterRuntimeID
    private let base: any FormatterRuntime
    private(set) var last: GenerationResult?

    init(_ base: any FormatterRuntime) {
        self.base = base
        self.id = base.id
    }

    func prepare(_ spec: RuntimeModelSpec, prefix: PromptPrefix) async throws { try await base.prepare(spec, prefix: prefix) }

    func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        last = nil
        let result = try await base.generate(request)
        last = result
        return result
    }

    func cancel(_ requestID: UUID) async { await base.cancel(requestID) }
    func unload() async { await base.unload() }

    func takeLast() -> GenerationResult? {
        defer { last = nil }
        return last
    }
}

public enum EvalRunner {
    /// Runs every case through the pipeline on `runtime`, one at a time (a server takes one request at a time).
    public static func run(
        cases: [EvalCase],
        runtime: any FormatterRuntime,
        promptBuilder: PromptBuilder,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [CaseResult] {
        let recorder = RecordingRuntime(runtime)
        let pipeline = FormatterPipeline(runtime: recorder, promptBuilder: promptBuilder)
        var results: [CaseResult] = []
        for (index, testCase) in cases.enumerated() {
            results.append(await runCase(testCase, pipeline: pipeline, recorder: recorder))
            progress?(index + 1, cases.count)
        }
        return results
    }

    static func runCase(_ testCase: EvalCase, pipeline: FormatterPipeline, recorder: RecordingRuntime) async -> CaseResult {
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await pipeline.format(testCase.raw, context: testCase.context)
        let elapsed = clock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        var modelText: String?
        if let last = await recorder.takeLast() {
            modelText = restoredModelText(last.text, for: testCase)
        }
        return CaseResult(
            id: testCase.id,
            context: testCase.context,
            kind: testCase.kind,
            outcome: outcome.reason == nil ? "formatted" : "raw",
            reason: outcome.reason?.rawValue,
            finalText: outcome.text,
            modelText: modelText,
            pipeline: Scorer.score(testCase, output: outcome.text),
            modelAlone: modelText.map { Scorer.score(testCase, output: $0) },
            seconds: seconds
        )
    }

    /// The model's text as the user would see it with no guards: sanitized when it can be, markers restored.
    static func restoredModelText(_ text: String, for testCase: EvalCase) -> String {
        let protected = TokenProtector.protect(FillerCleaner.clean(testCase.raw, context: testCase.context))
        let body: String
        switch OutputSanitizer.sanitize(text, input: protected.text) {
        case .success(let value): body = value
        case .failure: body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return protected.restore(body)
    }
}

extension EvalRunner {
    /// Feeds each case's own `expected` text back as the model answer. Not a quality score: it shows whether the
    /// guards accept an ideal answer, which finds bad templates and guards that are too strict.
    public static func runOracle(cases: [EvalCase], promptBuilder: PromptBuilder) async -> [CaseResult] {
        var results: [CaseResult] = []
        for testCase in cases {
            let protected = TokenProtector.protect(FillerCleaner.clean(testCase.raw, context: testCase.context))
            let recorder = RecordingRuntime(ReplayRuntime(output: Markerizer.markerize(testCase.expected, protected: protected)))
            let pipeline = FormatterPipeline(runtime: recorder, promptBuilder: promptBuilder)
            results.append(await runCase(testCase, pipeline: pipeline, recorder: recorder))
        }
        return results
    }
}
