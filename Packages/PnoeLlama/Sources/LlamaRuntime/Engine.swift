import FormatterCore
import Foundation
import llama

/// One loaded model with its context and the cached prompt prefix. Confined to `LlamaRuntime`'s queue.
final class Engine {
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let template: ChatTemplate
    private let bos: String
    private let contextLength: Int
    private let batchSize: Int

    private let modelURL: URL
    private let requestedContextLength: Int
    private let prefixMessages: PromptPrefix

    /// Tokens of the cached prefix, and how the cache gets back to them between requests.
    private var prefixTokens: [llama_token] = []
    private var prefixText = ""
    private var prefixState: [UInt8]?
    private let stopStrings = ["<turn|>", "<end_of_turn>"]

    init(modelURL: URL, contextLength: Int, prefix: PromptPrefix, configuration: LlamaRuntime.Configuration) throws {
        guard FileManager.default.isReadableFile(atPath: modelURL.path) else {
            throw FormatterRuntimeError.notReady
        }
        var modelParameters = llama_model_default_params()
        modelParameters.n_gpu_layers = configuration.gpuLayers
        modelParameters.load_mode = LLAMA_LOAD_MODE_MMAP
        guard let model = llama_model_load_from_file(modelURL.path, modelParameters) else {
            throw FormatterRuntimeError.failed("the model file could not be loaded")
        }

        let length = contextLength > 0 ? contextLength : 4096
        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = UInt32(length)
        contextParameters.n_batch = configuration.batchSize
        contextParameters.n_ubatch = configuration.batchSize
        contextParameters.n_seq_max = 1
        contextParameters.n_threads = configuration.threads
        contextParameters.n_threads_batch = configuration.threads
        contextParameters.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        // A full-size sliding-window cache lets `llama_memory_seq_rm` cut back to the prefix.
        contextParameters.swa_full = true
        contextParameters.no_perf = true
        guard let context = llama_init_from_model(model, contextParameters) else {
            llama_model_free(model)
            throw FormatterRuntimeError.failed("the context could not be created")
        }
        guard let vocab = llama_model_get_vocab(model) else {
            llama_free(context)
            llama_model_free(model)
            throw FormatterRuntimeError.failed("the model has no vocabulary")
        }

        let templateString = llama_model_chat_template(model, nil).map { String(cString: $0) }
        guard let template = ChatTemplate.detect(templateString: templateString) else {
            llama_free(context)
            llama_model_free(model)
            throw FormatterRuntimeError.failed("the model has no chat template")
        }

        self.model = model
        self.context = context
        self.vocab = vocab
        self.template = template
        self.contextLength = length
        self.batchSize = Int(configuration.batchSize)
        self.modelURL = modelURL
        self.requestedContextLength = contextLength
        self.prefixMessages = prefix
        let bosToken = llama_vocab_bos(vocab)
        self.bos = bosToken >= 0 ? (llama_vocab_get_text(vocab, bosToken).map { String(cString: $0) } ?? "<bos>") : "<bos>"

        // Every property is set, so a throw here still runs `deinit`, which frees the context and the model.
        try cachePrefix(prefix)
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    func matches(modelURL: URL, contextLength: Int, prefix: PromptPrefix) -> Bool {
        self.modelURL == modelURL && requestedContextLength == contextLength && prefixMessages == prefix
    }

    // MARK: Prefix cache

    private func cachePrefix(_ prefix: PromptPrefix) throws {
        prefixText = try render(prefix.messages, addGenerationPrompt: false)
        prefixTokens = try tokenize(prefixText, addSpecial: !template.rendersBeginningOfSequence)
        guard !prefixTokens.isEmpty, prefixTokens.count + 64 < contextLength else {
            throw FormatterRuntimeError.failed("the prompt prefix does not fit the context")
        }
        try decode(prefixTokens)

        // Probe: can the cache be cut back to the prefix? Decode one token past it and try.
        let probe = llama_vocab_nl(vocab) >= 0 ? llama_vocab_nl(vocab) : prefixTokens[0]
        try decode([probe])
        if llama_memory_seq_rm(llama_get_memory(context), 0, llama_pos(prefixTokens.count), -1) {
            prefixState = nil
        } else {
            // The sliding-window cache refuses a partial cut: keep the prefix state and restore it per request.
            llama_memory_clear(llama_get_memory(context), true)
            try decode(prefixTokens)
            let size = llama_state_seq_get_size(context, 0)
            var state = [UInt8](repeating: 0, count: size)
            let written = state.withUnsafeMutableBufferPointer { llama_state_seq_get_data(context, $0.baseAddress, size, 0) }
            guard written == size else { throw FormatterRuntimeError.failed("the prefix state could not be saved") }
            prefixState = state
        }
    }

    /// Puts the cache back to exactly the prefix.
    private func resetToPrefix() throws {
        let memory = llama_get_memory(context)
        if let prefixState {
            llama_memory_clear(memory, true)
            let restored = prefixState.withUnsafeBufferPointer {
                llama_state_seq_set_data(context, $0.baseAddress, prefixState.count, 0)
            }
            if restored == 0 {
                llama_memory_clear(memory, true)
                try decode(prefixTokens)
            }
        } else if !llama_memory_seq_rm(memory, 0, llama_pos(prefixTokens.count), -1) {
            llama_memory_clear(memory, true)
            try decode(prefixTokens)
        }
    }

    // MARK: Generation

    func generate(_ request: GenerationRequest, stop: StopCheck) throws -> GenerationResult {
        if stop.shouldStop { return GenerationResult(text: "", stopReason: .interrupted) }

        let split = try SplitPrompt.make(prefix: prefixMessages.messages, suffix: request.suffix) {
            try render($0, addGenerationPrompt: $1)
        }
        var tokens: [llama_token]
        if let split, split.prefix == prefixText {
            try resetToPrefix()
            tokens = try tokenize(split.suffix, addSpecial: false)
        } else {
            // The template rewrote the prefix: decode the whole prompt for this request.
            llama_memory_clear(llama_get_memory(context), true)
            let whole = try render(prefixMessages.messages + request.suffix, addGenerationPrompt: true)
            tokens = try tokenize(whole, addSpecial: !template.rendersBeginningOfSequence)
        }
        let position = llama_memory_seq_pos_max(llama_get_memory(context), 0) + 1
        let room = contextLength - Int(position) - tokens.count
        guard room > 1 else { throw FormatterRuntimeError.failed("the take does not fit the context") }
        let promptTokens = tokens.count

        try decode(tokens, stop: stop)
        if stop.shouldStop { return GenerationResult(text: "", stopReason: .interrupted, promptTokens: promptTokens) }

        let limit = min(request.maxTokens, room)
        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw FormatterRuntimeError.failed("the sampler could not be created")
        }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        var bytes: [UInt8] = []
        var generated = 0
        var reason = StopReason.cap
        while generated < limit {
            if stop.shouldStop {
                reason = .interrupted
                break
            }
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) || isStopText(token) {
                reason = .eos
                break
            }
            bytes += piece(for: token)
            generated += 1
            var next = [token]
            try decode(&next)
        }
        return GenerationResult(
            text: String(decoding: bytes, as: UTF8.self), stopReason: reason,
            promptTokens: promptTokens, generatedTokens: generated)
    }

    // MARK: Helpers

    private func render(_ messages: [ChatMessage], addGenerationPrompt: Bool) throws -> String {
        switch template {
        case .gemma4:
            return ChatTemplate.renderGemma4(messages, addGenerationPrompt: addGenerationPrompt, bos: bos)
        case .native(let templateString):
            return try applyNativeTemplate(templateString, messages: messages, addGenerationPrompt: addGenerationPrompt)
        }
    }

    private func applyNativeTemplate(_ templateString: String, messages: [ChatMessage], addGenerationPrompt: Bool) throws -> String {
        // The C strings must outlive the call.
        let roles = messages.map { strdup($0.role.rawValue) }
        let contents = messages.map { strdup($0.content) }
        defer {
            roles.forEach { free($0) }
            contents.forEach { free($0) }
        }
        let chat = zip(roles, contents).map { llama_chat_message(role: UnsafePointer($0), content: UnsafePointer($1)) }
        var capacity = max(1024, messages.reduce(0) { $0 + $1.content.utf8.count } * 2 + 256)
        for _ in 0..<2 {
            var buffer = [CChar](repeating: 0, count: capacity)
            let written = llama_chat_apply_template(
                templateString, chat, chat.count, addGenerationPrompt, &buffer, Int32(capacity))
            if written < 0 { throw FormatterRuntimeError.failed("the model's chat template is not supported") }
            if Int(written) <= capacity {
                return String(decoding: buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            capacity = Int(written) + 1
        }
        throw FormatterRuntimeError.failed("the chat template output did not fit")
    }

    private func tokenize(_ text: String, addSpecial: Bool) throws -> [llama_token] {
        let utf8Count = text.utf8.count
        var tokens = [llama_token](repeating: 0, count: utf8Count + 16)
        var count = llama_tokenize(vocab, text, Int32(utf8Count), &tokens, Int32(tokens.count), addSpecial, true)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, text, Int32(utf8Count), &tokens, Int32(tokens.count), addSpecial, true)
        }
        guard count >= 0 else { throw FormatterRuntimeError.failed("the text could not be tokenized") }
        return Array(tokens.prefix(Int(count)))
    }

    private func decode(_ tokens: [llama_token], stop: StopCheck? = nil) throws {
        var start = 0
        while start < tokens.count {
            if let stop, stop.shouldStop { return }
            var chunk = Array(tokens[start..<min(start + batchSize, tokens.count)])
            try decode(&chunk)
            start += chunk.count
        }
    }

    private func decode(_ tokens: inout [llama_token]) throws {
        let result = tokens.withUnsafeMutableBufferPointer { buffer in
            llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
        }
        guard result == 0 else { throw FormatterRuntimeError.failed("decoding failed (\(result))") }
    }

    private func piece(for token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if length < 0 {
            buffer = [CChar](repeating: 0, count: Int(-length))
            length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        guard length > 0 else { return [] }
        return buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
    }

    /// Insurance for a vocabulary that does not flag the turn-end token as end-of-generation.
    private func isStopText(_ token: llama_token) -> Bool {
        guard let text = llama_vocab_get_text(vocab, token) else { return false }
        return stopStrings.contains(String(cString: text))
    }
}
