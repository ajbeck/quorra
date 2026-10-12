import Synchronization

/// A clock that moves only when a test advances it.
package final class ManualClock: Clock {
    package struct Instant: InstantProtocol {
        package let offset: Duration
        package func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        package func duration(to other: Instant) -> Duration { other.offset - offset }
        package static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let id: Int
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID = 0
        var sleepers: [Sleeper] = []
        var sleeperWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private enum Outcome {
        case due, cancelled
        case sleeping(wake: [CheckedContinuation<Void, Never>])
    }

    private let state = Mutex(State())

    package init() {}

    package var now: Instant { state.withLock { $0.now } }
    package var minimumResolution: Duration { .zero }

    package func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Checking cancellation under the lock pairs with `onCancel`, which also takes it.
                let outcome = state.withLock { state -> Outcome in
                    if Task.isCancelled { return .cancelled }
                    if deadline <= state.now { return .due }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    defer { state.sleeperWaiters = [] }
                    return .sleeping(wake: state.sleeperWaiters)
                }
                switch outcome {
                case .due: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .sleeping(let waiters): for waiter in waiters { waiter.resume() }
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Returns once something is sleeping, so a following `advance` can't race the sleep's start.
    package func sleeperArrived() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if !state.sleepers.isEmpty { return true }
                state.sleeperWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    package func advance(by duration: Duration) {
        let due = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}
