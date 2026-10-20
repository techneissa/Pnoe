import FormatterCore
import Foundation
import Synchronization

/// Read by the decode loop between tokens.
struct StopCheck: Sendable {
    let flags: StopFlags
    let id: UUID
    let epoch: Int
    let deadline: ContinuousClock.Instant

    var shouldStop: Bool {
        if ContinuousClock.now >= deadline { return true }
        return flags.isStopped(id, epoch: epoch)
    }
}

/// Request ids cancelled before or while they run, and the unload epoch that stops a running decode. The
/// runtime's actor is busy while a request decodes, so `cancel` and `unload` go through this instead.
final class StopFlags: Sendable {
    private struct State {
        var cancelled: Set<UUID> = []
        var epoch = 0
    }

    private let state = Mutex(State())

    var epoch: Int { state.withLock { $0.epoch } }

    func cancel(_ id: UUID) {
        state.withLock {
            if $0.cancelled.count > 64 { $0.cancelled.removeAll() }
            $0.cancelled.insert(id)
        }
    }

    func forget(_ id: UUID) {
        state.withLock { _ = $0.cancelled.remove(id) }
    }

    func bumpEpoch() {
        state.withLock { $0.epoch += 1 }
    }

    func isStopped(_ id: UUID, epoch: Int) -> Bool {
        state.withLock { $0.cancelled.contains(id) || $0.epoch != epoch }
    }
}
