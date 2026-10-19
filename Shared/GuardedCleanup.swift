import FormatterCore
import FormatterOllama
import Foundation

/// Cleaned Text: the AI may fix punctuation, capitals, fillers and spoken corrections, nothing else.
/// The take runs through `FormatterPipeline` (protected paths and numbers, FormatterCore's own prompt,
/// sanitizer, placeholder check, word-diff and currency guards). Any guard failure pastes the plain
/// transcript, cleaned by code only, instead of the model's text.
struct GuardedCleanup {
    struct Result {
        /// The model's text when every guard passed, otherwise the plain transcript.
        let text: String
        /// Why the plain transcript was used (a `FallbackReason` code, never text), or nil.
        let fallbackReason: String?
        /// The system turn that was sent, for the history record.
        let systemPrompt: String
    }

    let runtime: any FormatterRuntime
    let spec: RuntimeModelSpec

    /// An Ollama server is reached the way the formatter package does it; every other provider goes through
    /// the app's own chat call, passed in as `complete`.
    static func make(
        ollamaBaseURL: String?,
        modelName: String,
        complete: @escaping ChatCompletionRuntime.Complete
    ) -> GuardedCleanup {
        let runtime: any FormatterRuntime
        if let ollamaBaseURL {
            runtime = OllamaRuntime(
                configuration: OllamaRuntime.Configuration(
                    defaultEndpoint: URL(string: ollamaBaseURL) ?? OllamaRuntime.Configuration().defaultEndpoint,
                    think: false,
                    warmUp: false
                ))
        } else {
            runtime = ChatCompletionRuntime(complete: complete)
        }
        return GuardedCleanup(runtime: runtime, spec: RuntimeModelSpec(identifier: modelName))
    }

    func clean(_ text: String, vocabulary: [String] = []) async -> Result {
        // The user is waiting on the paste, and a local model may still be loading: more room than the
        // package's default 3 s.
        var configuration = FormatterPipeline.Configuration()
        configuration.timeBudget = { words in .milliseconds(Int(min(20_000, 6_000 + 40 * Double(words)))) }
        guard let pipeline = try? FormatterPipeline.bundled(runtime: runtime, configuration: configuration) else {
            return Result(text: text, fallbackReason: FallbackReason.runtimeError.rawValue, systemPrompt: "")
        }
        let prefix = pipeline.prefix
        // A failed prepare shows up again as a runtime error from `generate`, which the pipeline turns
        // into the plain transcript.
        try? await runtime.prepare(spec, prefix: prefix)
        let outcome = await pipeline.format(text, context: .plain, vocabulary: vocabulary)
        return Result(
            text: outcome.text,
            fallbackReason: outcome.reason?.rawValue,
            systemPrompt: prefix.messages.first?.content ?? "")
    }

    /// Snippet placeholders (`⟦snippet-1⟧`) use the same brackets as the formatter's markers, so a take
    /// that has them skips the model and keeps the snippets for the caller to expand.
    static func canClean(_ text: String) -> Bool {
        !text.contains("⟦snippet-")
    }
}

/// `FormatterRuntime` over any provider the app already talks to. The caller supplies the one call that
/// sends a system prompt and chat turns and returns the model's text. The text carries no stop reason,
/// so it counts as a clean end; a cut-off reply is left to the word-diff guard.
actor ChatCompletionRuntime: FormatterRuntime {
    typealias Complete = @Sendable (_ system: String, _ turns: [(role: String, content: String)], _ timeout: TimeInterval) async throws -> String

    nonisolated let id: FormatterRuntimeID = .chatCompletion
    private let complete: Complete
    private var prefix = PromptPrefix(messages: [])

    init(complete: @escaping Complete) {
        self.complete = complete
    }

    func prepare(_ spec: RuntimeModelSpec, prefix: PromptPrefix) async throws {
        self.prefix = prefix
    }

    func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        guard let system = prefix.messages.first(where: { $0.role == .system })?.content else {
            throw FormatterRuntimeError.notReady
        }
        let turns = (prefix.messages.filter { $0.role != .system } + request.suffix)
            .map { (role: $0.role.rawValue, content: $0.content) }
        let remaining = request.deadline - ContinuousClock.now
        let parts = remaining.components
        let timeout = max(1, TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18)
        do {
            let text = try await complete(system, turns, timeout)
            return GenerationResult(text: text, stopReason: .eos)
        } catch is CancellationError {
            throw FormatterRuntimeError.cancelled
        } catch let error as FormatterRuntimeError {
            throw error
        } catch {
            throw FormatterRuntimeError.failed(String(describing: type(of: error)))
        }
    }

    func cancel(_ requestID: UUID) async {}

    func unload() async {}
}
