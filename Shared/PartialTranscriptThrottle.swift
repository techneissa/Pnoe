import Foundation

/// Decides when a partial transcript may reach the UI. Streaming providers send a partial every
/// few tens of milliseconds, far faster than the eye reads; this keeps the UI at one update per
/// `interval` and always delivers the newest text last.
///
/// Pure state, no timers: the caller asks what to do and does it. That keeps the rule testable
/// and keeps the transcription path free of any work beyond handing over a string.
struct PartialTranscriptThrottle {
    enum Decision: Equatable {
        /// Publish this text now.
        case publish(String)
        /// Hold the text; call `flush(now:)` at this time (seconds, same clock as `now`).
        case schedule(at: TimeInterval)
        /// A flush is already scheduled and will pick up the newest text.
        case hold
    }

    let interval: TimeInterval
    private var lastPublishedAt: TimeInterval?
    private var pending: String?
    private var flushScheduled = false

    init(interval: TimeInterval = 0.12) {
        self.interval = interval
    }

    mutating func submit(_ text: String, now: TimeInterval) -> Decision {
        guard let last = lastPublishedAt, now - last < interval else {
            lastPublishedAt = now
            pending = nil
            return .publish(text)
        }

        pending = text
        if flushScheduled { return .hold }
        flushScheduled = true
        return .schedule(at: last + interval)
    }

    /// Returns the held text, if any, and records it as published.
    mutating func flush(now: TimeInterval) -> String? {
        flushScheduled = false
        guard let text = pending else { return nil }
        pending = nil
        lastPublishedAt = now
        return text
    }

    /// Drops held text and starts over, so the next partial publishes at once.
    mutating func reset() {
        lastPublishedAt = nil
        pending = nil
        flushScheduled = false
    }
}

/// Feeds partial transcripts to `publish` through a `PartialTranscriptThrottle`.
@MainActor
final class PartialTranscriptRelay {
    private var throttle: PartialTranscriptThrottle
    private let publish: @MainActor (String) -> Void
    private let clock: () -> TimeInterval
    private var flushTask: Task<Void, Never>?

    init(
        interval: TimeInterval = 0.12,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        publish: @escaping @MainActor (String) -> Void
    ) {
        throttle = PartialTranscriptThrottle(interval: interval)
        self.clock = clock
        self.publish = publish
    }

    deinit {
        flushTask?.cancel()
    }

    func submit(_ text: String) {
        switch throttle.submit(text, now: clock()) {
        case .publish(let text):
            publish(text)
        case .schedule(let deadline):
            let delay = max(0, deadline - clock())
            flushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                if let text = self.throttle.flush(now: self.clock()) {
                    self.publish(text)
                }
            }
        case .hold:
            break
        }
    }

    func reset() {
        flushTask?.cancel()
        flushTask = nil
        throttle.reset()
    }
}
