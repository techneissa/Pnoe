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
        // Snippet placeholders travel through the formatter as protected terms and come back unchanged.
        let snippets = SnippetKeeper(text)
        let result = await cleanProtected(snippets.text, vocabulary: vocabulary + snippets.terms)
        return Result(
            text: snippets.restore(result.text),
            fallbackReason: result.fallbackReason,
            systemPrompt: result.systemPrompt)
    }

    private func cleanProtected(_ text: String, vocabulary: [String]) async -> Result {
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
}

/// Snippet placeholders (`⟦snippet-1⟧`) use the same brackets as the formatter's markers, and the formatter
/// strips those brackets. So each placeholder is swapped for a plain letters-only word the formatter keeps as
/// a protected term, and swapped back afterwards. The model never sees either form; it sees a marker.
struct SnippetKeeper {
    let text: String
    /// The stand-in words, to pass to the formatter as vocabulary.
    let terms: [String]
    private let placeholders: [String]

    private static let pattern = try! NSRegularExpression(pattern: "⟦snippet-[0-9]+⟧")

    init(_ original: String) {
        var found: [String] = []
        for match in Self.pattern.matches(in: original, range: NSRange(original.startIndex..., in: original)) {
            guard let range = Range(match.range, in: original) else { continue }
            let placeholder = String(original[range])
            if !found.contains(placeholder) { found.append(placeholder) }
        }
        var result = original
        var stand: [String] = []
        for (index, placeholder) in found.enumerated() {
            let word = Self.word(for: index)
            stand.append(word)
            result = result.replacingOccurrences(of: placeholder, with: word)
        }
        text = result
        terms = stand
        placeholders = found
    }

    func restore(_ output: String) -> String {
        var result = output
        // Highest index first: a longer stand-in ("snippetkeepaa") must go before the shorter one it starts with.
        for (index, placeholder) in placeholders.enumerated().reversed() {
            result = result.replacingOccurrences(of: Self.word(for: index), with: placeholder)
        }
        return result
    }

    /// `snippetkeepa`, `snippetkeepb`, … `snippetkeepaa`: letters only, so no number rule touches them.
    private static func word(for index: Int) -> String {
        var n = index
        var letters = ""
        repeat {
            letters = String(UnicodeScalar(UInt8(97 + n % 26))) + letters
            n = n / 26 - 1
        } while n >= 0
        return "snippetkeep" + letters
    }
}

/// `FormatterRuntime` over any provider the app already talks to. The caller supplies the one call that
/// sends a system prompt and chat turns and returns the model's text and, when the provider reports one,
/// its finish reason. A reply that hit the length limit counts as cut off. A provider that reports nothing
/// counts as finished, and a cut-off reply from it is left to the word-diff guard.
actor ChatCompletionRuntime: FormatterRuntime {
    struct Completion: Sendable {
        let text: String
        /// The provider's own word: `length` (OpenAI-compatible), `max_tokens` (Anthropic), `MAX_TOKENS` (Gemini).
        let finishReason: String?

        init(text: String, finishReason: String? = nil) {
            self.text = text
            self.finishReason = finishReason
        }

        var wasCutOff: Bool {
            guard let reason = finishReason?.lowercased() else { return false }
            return ["length", "max_tokens", "max_output_tokens"].contains(reason)
        }
    }

    typealias Complete = @Sendable (_ system: String, _ turns: [(role: String, content: String)], _ timeout: TimeInterval) async throws -> Completion

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
            let completion = try await complete(system, turns, timeout)
            return GenerationResult(text: completion.text, stopReason: completion.wasCutOff ? .cap : .eos)
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
