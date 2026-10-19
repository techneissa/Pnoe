import Foundation
import os

/// Live text for WhisperKit models while the user speaks.
///
/// WhisperKit has no streaming API that accepts outside audio (its `AudioStreamTranscriber` opens
/// the microphone itself), so this feeds the recorder's 16 kHz buffers to a `WhisperKitLiveSession`:
/// a rolling window that is re-decoded every ~0.75 s on the shared `WhisperKitEngine` and published
/// as partials. The partials only drive the live line. At stop the provider asks for the batch path
/// (`useBatchFallback`), so the final text is one full decode of the whole take, as without live text.
final class WhisperKitStreamingProvider: StreamingTranscriptionProvider {
    private let service: WhisperKitTranscriptionService
    private let model: WhisperKitModel
    private let prompt: String?
    private let logger = Logger(subsystem: "com.techneissa.pnoe", category: "WhisperKitStreaming")

    private var session: WhisperKitLiveSession?
    private let eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation
    let transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    /// The final text always comes from the full recording.
    var stopDisposition: StreamingStopDisposition { .useBatchFallback }

    init(service: WhisperKitTranscriptionService, model: WhisperKitModel, prompt: String?) {
        self.service = service
        self.model = model
        self.prompt = prompt
        let (stream, continuation) = AsyncStream.makeStream(of: StreamingTranscriptionEvent.self)
        transcriptionEvents = stream
        eventsContinuation = continuation
    }

    deinit {
        eventsContinuation.finish()
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        // Loading here (not on the first window) keeps a live pass from ever waiting on a load.
        try await service.loadModel(for: self.model)
        let continuation = eventsContinuation
        let session = WhisperKitLiveSession(
            decoder: try service.liveDecoder(for: self.model),
            language: language,
            prompt: prompt,
            onPartial: { continuation.yield(.partial(text: $0)) }
        )
        self.session = session
        await session.start()
        continuation.yield(.sessionStarted)
        logger.notice("WhisperKit live text started for \(self.model.displayName, privacy: .public)")
    }

    func sendAudioChunk(_ data: Data) async throws {
        await session?.append(PCMAudioConverter.float32Samples(fromPCM16Data: data))
    }

    /// Nothing to commit: the batch path decodes the take.
    func commit() async throws {
        await session?.stop()
    }

    func disconnect() async {
        await session?.stop()
        session = nil
        eventsContinuation.finish()
    }
}
