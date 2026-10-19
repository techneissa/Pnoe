import Foundation

/// What the pipeline hands back. It never throws: every failure is `.raw` with a reason code.
public enum FormatterOutcome: Sendable, Equatable {
    case formatted(String)
    /// The model was not used or its output was rejected. The text is the code-cleaned take.
    case raw(String, FallbackReason)

    public var text: String {
        switch self {
        case .formatted(let text), .raw(let text, _): text
        }
    }

    public var reason: FallbackReason? {
        if case .raw(_, let reason) = self { reason } else { nil }
    }
}

/// Chains the guards around one runtime call: filler cleanup, skip rule, normalize and protect, prompt,
/// generate, sanitize, placeholder check, restore, word-diff guard, finish.
public struct FormatterPipeline: Sendable {
    public struct Configuration: Sendable {
        /// Wall-clock budget for one generation: 3 s plus 0.03 s per word, capped at 12 s.
        public var timeBudget: @Sendable (_ words: Int) -> Duration = { words in
            .milliseconds(Int(min(12_000, 3_000 + 30 * Double(words))))
        }
        /// Generation cap: 1.6 times the input tokens plus 48.
        public var maxTokens: @Sendable (_ inputTokens: Int) -> Int = { Int((1.6 * Double($0)).rounded(.up)) + 48 }
        public var thresholds: @Sendable (FormatterContext) -> WordDiffThresholds = { WordDiffThresholds.defaults(for: $0) }

        public init() {}
    }

    private let runtime: any FormatterRuntime
    private let promptBuilder: PromptBuilder
    private let configuration: Configuration

    public init(runtime: any FormatterRuntime, promptBuilder: PromptBuilder, configuration: Configuration = Configuration()) {
        self.runtime = runtime
        self.promptBuilder = promptBuilder
        self.configuration = configuration
    }

    /// A pipeline with the prompt files shipped in the package.
    public static func bundled(runtime: any FormatterRuntime, configuration: Configuration = Configuration()) throws -> FormatterPipeline {
        FormatterPipeline(runtime: runtime, promptBuilder: try .bundled(), configuration: configuration)
    }

    /// The prefix a runtime should `prepare` with.
    public var prefix: PromptPrefix { promptBuilder.prefix }

    public func format(_ text: String, context: FormatterContext, vocabulary: [String] = []) async -> FormatterOutcome {
        // 1. Filler cleanup.
        let cleaned = FillerCleaner.clean(text, context: context)
        guard SkipRule.wordCount(cleaned) > 0 else { return .raw(cleaned, .emptyInput) }

        // 3. Normalize and protect (spoken forms written out, exact spans swapped for markers).
        let protected = TokenProtector.protect(cleaned, vocabulary: vocabulary)
        let fallback = protected.normalized

        // 2. Skip: under 4 words never reach the model. Counted after step 3, so "tom at example dot com"
        // is one word. Formatting runs on the marker text so a path or address never gets a capital.
        if SkipRule.shouldSkip(protected.text) {
            return .raw(protected.restore(SkipRule.format(protected.text, context: context)), .tooShort)
        }

        // 4. Prompt, 5. generate.
        let words = SkipRule.wordCount(protected.text)
        let request = GenerationRequest(
            suffix: promptBuilder.suffix(transcript: protected.text, context: context),
            maxTokens: configuration.maxTokens(estimatedTokens(protected.text)),
            deadline: .now + configuration.timeBudget(words)
        )
        let result: GenerationResult
        do {
            result = try await generate(request, budget: configuration.timeBudget(words))
        } catch let reason as FallbackReason {
            return .raw(fallback, reason)
        } catch let error as FormatterRuntimeError {
            return .raw(fallback, reason(for: error))
        } catch is CancellationError {
            return .raw(fallback, .cancelled)
        } catch {
            return .raw(fallback, .runtimeError)
        }
        if Task.isCancelled { return .raw(fallback, .cancelled) }
        if result.stopReason == .cap { return .raw(fallback, .truncated) }

        // 6. Sanitize.
        let sanitized: String
        switch OutputSanitizer.sanitize(result.text, input: protected.text) {
        case .success(let value): sanitized = value
        case .failure(let reason): return .raw(fallback, reason)
        }

        // 7. Placeholders, then restore.
        if let reason = PlaceholderCheck.validate(sanitized, protected: protected) { return .raw(fallback, reason) }
        let restored = protected.restore(sanitized)

        // 8. Word-diff guard against the written-out input.
        let thresholds = configuration.thresholds(context)
        if let reason = WordDiffGuard.check(input: protected.normalized, output: restored, context: context, thresholds: thresholds) {
            return .raw(fallback, reason)
        }

        // 9. Finish.
        return .formatted(finish(restored))
    }

    // MARK: - Steps

    private func generate(_ request: GenerationRequest, budget: Duration) async throws -> GenerationResult {
        let runtime = self.runtime
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: GenerationResult?.self) { group in
                group.addTask { try await runtime.generate(request) }
                group.addTask {
                    try await Task.sleep(for: budget)
                    return nil
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw FallbackReason.runtimeError }
                guard let result = first else {
                    // The deadline passed first: stop the decode loop so the group can finish.
                    await runtime.cancel(request.id)
                    throw FallbackReason.timeout
                }
                return result
            }
        } onCancel: {
            Task { await runtime.cancel(request.id) }
        }
    }

    private func reason(for error: FormatterRuntimeError) -> FallbackReason {
        switch error {
        case .modelLoading: .modelLoading
        case .notReady: .modelNotReady
        case .crashed: .runtimeCrashed
        case .cancelled: .cancelled
        case .failed: .runtimeError
        }
    }

    /// Rough token count without a tokenizer: about 3 characters per token, which leans high on purpose
    /// (a markers-heavy take costs more tokens per character).
    private func estimatedTokens(_ text: String) -> Int {
        max(1, Int((Double(text.count) / 3).rounded(.up)))
    }

    private func finish(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacing(#/\n{3,}/#, with: "\n\n")
    }
}
