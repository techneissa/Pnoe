import FormatterCore
import FormatterMLXSupport
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Owns the loaded model, its tokenizer and the prefix snapshot. An actor, so prepare and generate never overlap
/// on the model; `MLXRuntime` reaches the decode loop through `StopCheck` instead of the actor.
actor MLXHost {
    private var loaded: LoadedModel?

    func prepare(modelURL: URL, contextLength: Int, prefix: PromptPrefix) async throws {
        let url = modelURL.standardizedFileURL
        if let current = loaded, current.matches(url: url, contextLength: contextLength) {
            if current.hasPrefix(prefix) { return }
            do {
                try current.setPrefix(prefix)
            } catch {
                loaded = nil
                throw error
            }
            return
        }
        loaded = nil
        let fresh = try await LoadedModel.load(url: url, contextLength: contextLength)
        do {
            try fresh.setPrefix(prefix)
        } catch {
            throw error
        }
        loaded = fresh
    }

    func generate(_ request: GenerationRequest, stop: StopCheck) throws -> GenerationResult {
        guard let loaded else { throw FormatterRuntimeError.notReady }
        return try loaded.generate(request, stop: stop)
    }

    func unload() {
        loaded = nil
        MLX.Memory.clearCache()
    }
}

/// One loaded model with its cached prompt prefix. Confined to `MLXHost`.
final class LoadedModel {
    private let context: ModelContext
    private let upstream: any Tokenizers.Tokenizer
    private let template: String
    private let url: URL
    private let requestedContextLength: Int
    private let contextLength: Int
    private let stopTokenIDs: Set<Int>
    private let parameters = GenerateParameters(maxTokens: nil, temperature: 0)

    private var prefixMessages = PromptPrefix(messages: [])
    private var prefixTokens: [Int] = []
    /// The KV cache after the prefix, copied for each request, and the per-call model state that goes with it.
    private var snapshot: [KVCache] = []
    private var snapshotState: LMOutput.State?

    private init(
        context: ModelContext, upstream: any Tokenizers.Tokenizer, template: String, url: URL,
        contextLength: Int, requestedContextLength: Int
    ) {
        self.context = context
        self.upstream = upstream
        self.template = template
        self.url = url
        self.contextLength = contextLength
        self.requestedContextLength = requestedContextLength

        // Every end-of-sequence id the model declares, plus the turn-end tokens by text as insurance for a model
        // whose generation config does not list them.
        var stop = context.configuration.eosTokenIds
        if let id = context.tokenizer.eosTokenId { stop.insert(id) }
        for text in context.configuration.extraEOSTokens + MLXChatTemplate.stopTexts {
            if let id = context.tokenizer.convertTokenToId(text) { stop.insert(id) }
        }
        stopTokenIDs = stop
    }

    static func load(url: URL, contextLength: Int) async throws -> LoadedModel {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw FormatterRuntimeError.notReady }
        guard let template = MLXChatTemplate.source(inFolder: url) else {
            throw FormatterRuntimeError.failed("the model has no chat template")
        }
        let context: ModelContext
        do {
            context = try await loadModel(from: url, using: LocalTokenizerLoader())
        } catch {
            throw FormatterRuntimeError.failed("the MLX model could not be loaded: \(error.localizedDescription)")
        }
        guard let bridge = context.tokenizer as? TokenizerBridge else {
            throw FormatterRuntimeError.failed("the model's tokenizer could not be loaded")
        }
        return LoadedModel(
            context: context, upstream: bridge.upstream, template: template, url: url,
            contextLength: contextLength > 0 ? contextLength : 4096, requestedContextLength: contextLength)
    }

    func matches(url: URL, contextLength: Int) -> Bool {
        self.url == url && requestedContextLength == contextLength
    }

    func hasPrefix(_ prefix: PromptPrefix) -> Bool {
        prefixMessages == prefix && !prefixTokens.isEmpty
    }

    // MARK: Prefix cache

    /// Runs a new fixed prompt prefix through the loaded model and keeps the cache. The model stays loaded, so a
    /// workflow with another system prompt does not pay for a reload.
    func setPrefix(_ prefix: PromptPrefix) throws {
        prefixMessages = prefix
        prefixTokens = []
        snapshot = []
        snapshotState = nil

        let tokens = try render(prefix.messages, addGenerationPrompt: false)
        guard !tokens.isEmpty, tokens.count + 64 < contextLength else {
            throw FormatterRuntimeError.failed("the prompt prefix does not fit the context")
        }
        do {
            let cache = try context.model.newCache(parameters: parameters)
            // The iterator prefills the prompt into `cache` when it is made; no token is taken from it.
            let iterator = try TokenIterator(
                input: LMInput(tokens: MLXArray(tokens)), model: context.model, cache: cache, parameters: parameters)
            eval(cache.flatMap { $0.state })
            snapshotState = iterator.state
            snapshot = cache
        } catch let error as FormatterRuntimeError {
            throw error
        } catch {
            throw FormatterRuntimeError.failed("the prompt prefix could not be evaluated: \(error.localizedDescription)")
        }
        prefixTokens = tokens
    }

    // MARK: Generation

    func generate(_ request: GenerationRequest, stop: StopCheck) throws -> GenerationResult {
        if stop.shouldStop { return GenerationResult(text: "", stopReason: .interrupted) }

        let whole = try render(prefixMessages.messages + request.suffix, addGenerationPrompt: true)
        let cache: [KVCache]
        let state: LMOutput.State?
        let input: [Int]
        var cachedCount = 0
        if let suffix = MLXChatTemplate.suffix(of: whole, afterPrefix: prefixTokens) {
            cache = snapshot.map { $0.copy() }
            state = snapshotState
            input = suffix
            cachedCount = prefixTokens.count
        } else {
            // The template rewrote the prefix: decode the whole prompt for this request.
            cache = try context.model.newCache(parameters: parameters)
            state = nil
            input = whole
        }
        let room = contextLength - cachedCount - input.count
        guard room > 1 else { throw FormatterRuntimeError.failed("the take does not fit the context") }
        let limit = min(request.maxTokens, room)

        var parameters = self.parameters
        parameters.maxTokens = limit
        var iterator: TokenIterator
        do {
            iterator = try TokenIterator(
                input: LMInput(tokens: MLXArray(input)), model: context.model, cache: cache, state: state,
                parameters: parameters)
        } catch {
            throw FormatterRuntimeError.failed("the prompt could not be evaluated: \(error.localizedDescription)")
        }
        defer { Stream.defaultStream(.gpu).synchronize() }
        if stop.shouldStop { return GenerationResult(text: "", stopReason: .interrupted, promptTokens: input.count) }

        var generated: [Int] = []
        var reason = StopReason.cap
        while true {
            if stop.shouldStop {
                reason = .interrupted
                break
            }
            guard let token = autoreleasepool(invoking: { iterator.next() }) else {
                reason = .cap
                break
            }
            if stopTokenIDs.contains(token) {
                reason = .eos
                break
            }
            generated.append(token)
        }
        return GenerationResult(
            text: upstream.decode(tokens: generated, skipSpecialTokens: true), stopReason: reason,
            promptTokens: input.count, generatedTokens: generated.count)
    }

    // MARK: Template

    /// Token ids of `messages` under the model's chat template. With a generation prompt, a template that thinks
    /// ends in the closed, empty think block.
    private func render(_ messages: [ChatMessage], addGenerationPrompt: Bool) throws -> [Int] {
        let turns: [Tokenizers.Message] = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        var tokens: [Int]
        do {
            tokens = try upstream.applyChatTemplate(
                messages: turns, chatTemplate: .literal(template), addGenerationPrompt: addGenerationPrompt,
                truncation: false, maxLength: nil, tools: nil, additionalContext: ["enable_thinking": false])
        } catch {
            throw FormatterRuntimeError.failed("the model's chat template could not be applied: \(error.localizedDescription)")
        }
        if addGenerationPrompt {
            let tail = upstream.decode(tokens: Array(tokens.suffix(16)), skipSpecialTokens: false)
            if let closing = MLXChatTemplate.closingThinking(template: template, promptTail: tail) {
                tokens += upstream.encode(text: closing, addSpecialTokens: false)
            }
        }
        return tokens
    }
}
