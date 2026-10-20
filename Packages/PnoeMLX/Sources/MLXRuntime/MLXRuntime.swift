import FormatterCore
import Foundation

/// `FormatterRuntime` over mlx-swift-lm. It runs inside the MLX XPC service, never in the app and never in the
/// llama.cpp service, so an MLX crash (a Metal fault, an unsupported tensor) ends only that process.
///
/// - Model: an MLX folder (`config.json`, safetensors, tokenizer files), loaded offline from where it already
///   is. Nothing is downloaded.
/// - Prompt: the model folder's own chat template (`chat_template.jinja` or `tokenizer_config.json`), rendered by
///   swift-transformers; a template that thinks gets the empty think block after the generation prompt, as the
///   llama engine does.
/// - Decoding: greedy (temperature 0), stop at an end-of-sequence token or the token cap.
/// - Prefix cache: `prepare` runs the fixed prompt prefix once and keeps a snapshot of the KV cache. A request
///   copies the snapshot and runs only its own turn. (`ChatSession.fork` reuses no cache for Gemma 4, so the
///   snapshot is kept here.)
/// - Threads: one actor owns the model; `cancel` and `unload` only set flags the decode loop reads each token.
public final class MLXRuntime: FormatterRuntime, @unchecked Sendable {
    public let id: FormatterRuntimeID = .mlx

    private let flags = StopFlags()
    private let host = MLXHost()

    public init() {}

    // MARK: FormatterRuntime

    public func prepare(_ spec: RuntimeModelSpec, prefix: PromptPrefix) async throws {
        guard let modelURL = spec.modelURL else { throw FormatterRuntimeError.failed("the model has no folder") }
        try await host.prepare(modelURL: modelURL, contextLength: spec.contextLength, prefix: prefix)
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        let epoch = flags.epoch
        defer { flags.forget(request.id) }
        let stop = StopCheck(flags: flags, id: request.id, epoch: epoch, deadline: request.deadline)
        return try await host.generate(request, stop: stop)
    }

    public func cancel(_ requestID: UUID) async {
        flags.cancel(requestID)
    }

    /// Stops a running decode, then frees the model, its cache and the GPU buffers.
    public func unload() async {
        flags.bumpEpoch()
        await host.unload()
    }
}
