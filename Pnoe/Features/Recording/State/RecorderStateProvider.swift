import Foundation

// Protocol for objects that provide live recorder state to the UI.
@MainActor
protocol RecorderStateProvider: AnyObject {
    var recordingState: RecordingState { get }
    var partialTranscript: String { get }
    /// True while the engine in use sends partial transcripts, so the recorder can reserve the
    /// live line before the first words arrive.
    var expectsPartialTranscript: Bool { get }
}
