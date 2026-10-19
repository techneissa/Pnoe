import Foundation
import os

/// One piece of text WhisperKit decoded from a live window, with its position in that window.
struct WhisperKitLiveSegment: Equatable, Sendable {
    let text: String
    /// Seconds from the start of the decoded window.
    let start: Double
    let end: Double
}

struct WhisperKitLiveResult: Equatable, Sendable {
    let segments: [WhisperKitLiveSegment]
    /// The language Whisper detected, when the caller asked it to detect.
    let language: String?
}

/// What the live session needs to decode a window of audio.
protocol WhisperKitLiveDecoding: Sendable {
    /// Decodes 16 kHz mono samples. Returns nil when the engine is busy or has no model loaded: the
    /// window is dropped, never queued behind other work.
    func decodeLive(samples: [Float], language: String?, prompt: String?) async throws -> WhisperKitLiveResult?
}

/// Decides which window of the recording to decode next, and turns the decoded segments into the
/// text shown on the live line. Pure state: no clock, no audio, no model.
///
/// The rule is the simple rolling window. Every pass decodes the audio since the window start. Once
/// the window passes `commitAfterSeconds`, every segment but the last is final: its text moves into
/// `confirmedText` (and becomes the prompt for the next passes) and the window start moves to where
/// the last confirmed segment ended. A window that reaches `maxWindowSeconds` without a second
/// segment is confirmed whole, so one decode never grows past what Whisper reads in one go.
struct WhisperKitLivePlanner {
    struct Settings: Equatable {
        var sampleRate = 16_000
        /// No pass before this much audio exists.
        var minWindowSeconds = 1.0
        /// No pass before this much new audio arrived since the last one.
        var minNewSeconds = 0.5
        var commitAfterSeconds = 20.0
        var maxWindowSeconds = 28.0
        /// New audio quieter than this (RMS) is skipped: Whisper invents text for silence.
        var silenceRMS: Float = 0.002
        /// How much confirmed text rides along as the prompt.
        var promptTailCharacters = 200
    }

    struct Request: Equatable {
        /// Absolute sample positions in the recording.
        let windowStart: Int
        let windowEnd: Int
        let prompt: String?
        let language: String?
    }

    let settings: Settings
    private let basePrompt: String?
    private let configuredLanguage: String?
    private var pinnedLanguage: String?

    private(set) var windowStart = 0
    private(set) var lastHandledEnd = 0
    private(set) var confirmedText = ""
    /// The unconfirmed text of the last decoded window.
    private var hypothesis = ""

    init(settings: Settings = Settings(), language: String?, prompt: String?) {
        self.settings = settings
        self.configuredLanguage = language
        self.basePrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// The next window to decode, or nil when it is too early.
    func nextRequest(totalSamples: Int) -> Request? {
        let rate = Double(settings.sampleRate)
        guard Double(totalSamples - windowStart) >= settings.minWindowSeconds * rate else { return nil }
        guard Double(totalSamples - lastHandledEnd) >= settings.minNewSeconds * rate else { return nil }
        return Request(
            windowStart: windowStart,
            windowEnd: totalSamples,
            prompt: prompt(),
            language: configuredLanguage ?? pinnedLanguage
        )
    }

    /// The pass for this window did not produce text (the new audio was silent, or the decode failed).
    /// The text shown so far is final, and the window moves on: a long pause or an error never makes
    /// the next window grow.
    mutating func skip(_ request: Request) {
        lastHandledEnd = request.windowEnd
        confirmedText = Self.join([confirmedText, hypothesis])
        hypothesis = ""
        windowStart = request.windowEnd
    }

    /// Takes a decoded window and returns the full text for the live line.
    mutating func apply(_ result: WhisperKitLiveResult, to request: Request) -> String {
        lastHandledEnd = request.windowEnd
        if configuredLanguage == nil, pinnedLanguage == nil, let detected = result.language, !detected.isEmpty {
            pinnedLanguage = detected
        }

        let segments = result.segments.filter { !Self.isNoise($0.text) }
        let texts = Self.withoutRepeatedTail(of: confirmedText, in: segments.map { Self.clean($0.text) })
        let rate = Double(settings.sampleRate)
        let windowSeconds = Double(request.windowEnd - request.windowStart) / rate

        var confirmedCount = 0
        var nextStart: Int?
        if windowSeconds >= settings.maxWindowSeconds {
            // Past the limit the window always moves on, even when it held nothing but tags.
            confirmedCount = segments.count
            nextStart = request.windowEnd
        } else if windowSeconds >= settings.commitAfterSeconds, segments.count >= 2 {
            confirmedCount = segments.count - 1
            let end = segments[confirmedCount - 1].end
            nextStart = min(request.windowEnd, request.windowStart + Int(end * rate))
        }

        if let nextStart {
            confirmedText = Self.join([confirmedText] + texts.prefix(confirmedCount))
            windowStart = nextStart
        }
        hypothesis = Self.join(Array(texts.dropFirst(confirmedCount)))
        return Self.join([confirmedText, hypothesis])
    }

    private func prompt() -> String? {
        let tail = String(confirmedText.suffix(settings.promptTailCharacters))
        return Self.join([basePrompt ?? "", tail]).nilIfEmpty
    }

    /// The window starts at a segment boundary, and Whisper sometimes repeats the last words of
    /// the text before it. Drops up to `seamWords` leading words that repeat the tail of the confirmed text.
    private static let seamWords = 5

    private static func withoutRepeatedTail(of confirmed: String, in texts: [String]) -> [String] {
        let tail = confirmed.split(whereSeparator: \.isWhitespace).suffix(seamWords).map { normalized(String($0)) }
        let words = texts.map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        let leading = words.flatMap { $0 }.prefix(seamWords).map(normalized)
        guard !tail.isEmpty, !leading.isEmpty else { return texts }

        var drop = 0
        for count in stride(from: min(tail.count, leading.count), through: 1, by: -1) {
            let a = Array(tail.suffix(count)), b = Array(leading.prefix(count))
            if a == b, !a.contains("") {
                drop = count
                break
            }
        }
        guard drop > 0 else { return texts }

        var remaining = drop
        return words.map { segmentWords in
            let cut = min(remaining, segmentWords.count)
            remaining -= cut
            return segmentWords.dropFirst(cut).joined(separator: " ")
        }
    }

    private static func normalized(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func join(_ parts: [String]) -> String {
        parts.map(clean).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Whisper marks silence and sound with a bracketed tag such as "[BLANK_AUDIO]" or "(music)".
    private static func isNoise(_ text: String) -> Bool {
        let trimmed = clean(text)
        if trimmed.isEmpty { return true }
        return (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) || (trimmed.hasPrefix("(") && trimmed.hasSuffix(")"))
    }
}

/// Feeds the recorder's audio to WhisperKit while the user speaks and reports the live text.
///
/// A loop asks for a pass every `interval`. A pass decodes the current window through the
/// `WhisperKitLiveDecoding` it was given; one pass runs at a time, and a tick that finds the previous
/// pass still running does nothing. The text it publishes is a hint for the live line only: the
/// final transcript of the take is decoded from the whole recording by the batch path.
actor WhisperKitLiveSession {
    private let decoder: any WhisperKitLiveDecoding
    private let onPartial: @Sendable (String) -> Void
    private let logger = Logger(subsystem: "com.techneissa.pnoe", category: "WhisperKitLiveSession")

    private var planner: WhisperKitLivePlanner
    private var buffer: [Float] = []
    /// Absolute sample index of `buffer[0]`.
    private var bufferStart = 0
    private var isDecoding = false
    private var isStopped = false
    private var loop: Task<Void, Never>?
    private var decodeTask: Task<WhisperKitLiveResult?, Error>?
    private var lastPartial = ""

    init(
        decoder: any WhisperKitLiveDecoding,
        language: String?,
        prompt: String?,
        settings: WhisperKitLivePlanner.Settings = .init(),
        onPartial: @escaping @Sendable (String) -> Void
    ) {
        self.decoder = decoder
        self.onPartial = onPartial
        self.planner = WhisperKitLivePlanner(
            settings: settings,
            language: WhisperKitEngine.languageCode(from: language),
            prompt: prompt
        )
    }

    /// Runs `tick()` every `interval` until `stop()`.
    func start(interval: Duration = .milliseconds(750)) {
        guard loop == nil, !isStopped else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                // A released session ends its own loop.
                guard let self else { return }
                await self.tick()
            }
        }
    }

    func append(_ samples: [Float]) {
        guard !isStopped else { return }
        buffer.append(contentsOf: samples)
    }

    /// One pass: decodes the window if there is enough new audio and no pass is running.
    func tick() async {
        guard !isStopped, !isDecoding else { return }
        guard let request = planner.nextRequest(totalSamples: bufferStart + buffer.count) else { return }

        let from = request.windowStart - bufferStart
        let to = request.windowEnd - bufferStart

        // Silence is judged on the new audio, before anything is copied: a pause moves the window on.
        let newFrom = max(planner.lastHandledEnd, request.windowStart) - bufferStart
        if Self.rms(of: buffer[newFrom..<to]) < planner.settings.silenceRMS {
            planner.skip(request)
            trimBuffer()
            return
        }
        let window = Array(buffer[from..<to])

        isDecoding = true
        defer { isDecoding = false }

        let decoder = decoder
        let task = Task { try await decoder.decodeLive(samples: window, language: request.language, prompt: request.prompt) }
        decodeTask = task
        let result: WhisperKitLiveResult?
        do {
            result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            decodeTask = nil
            if !(error is CancellationError) {
                logger.error("Live pass failed: \(error.localizedDescription, privacy: .public)")
                // Move on, so one repeating error cannot stop the live text for the rest of the take.
                if !isStopped {
                    planner.skip(request)
                    trimBuffer()
                }
            }
            return
        }
        decodeTask = nil
        // Stopped while the pass ran: its text belongs to a session nobody watches any more.
        guard !isStopped, let result else { return }

        let text = planner.apply(result, to: request)
        trimBuffer()
        if text != lastPartial {
            lastPartial = text
            onPartial(text)
        }
    }

    /// Stops the loop, cancels a running pass and waits for both. Nothing is published after this.
    func stop() async {
        isStopped = true
        let loop = loop
        let running = decodeTask
        self.loop = nil
        loop?.cancel()
        running?.cancel()
        await loop?.value
        _ = try? await running?.value
        buffer = []
    }

    private func trimBuffer() {
        let drop = planner.windowStart - bufferStart
        guard drop > 0 else { return }
        buffer.removeFirst(min(drop, buffer.count))
        bufferStart += drop
    }

    private static func rms(of samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }
}

/// Decodes live windows on a `WhisperKitEngine`, for one model.
struct WhisperKitEngineLiveDecoder: WhisperKitLiveDecoding {
    let engine: WhisperKitEngine
    let spec: WhisperKitModelSpec

    func decodeLive(samples: [Float], language: String?, prompt: String?) async throws -> WhisperKitLiveResult? {
        try await engine.transcribeLive(samples: samples, spec: spec, language: language, prompt: prompt)
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
