import Foundation

extension IdentityCenterService {
    // MARK: - Per-session async serialization (D21)
    //
    // Problem: Swift actors guarantee serialization only between suspension points. When
    // `signOut` (or any other operation) calls `await urlSession.data(for:)`, the actor
    // releases its lock and a concurrent `refresh` Task can interleave — actor reentrancy.
    // WWDC21 "Protect mutable state with Swift actors" covers this directly.
    //
    // Why Synchronization.Mutex is wrong: `Mutex.withLock` is synchronous and blocking —
    // it blocks the OS thread. Apple's docs and WWDC21 are explicit: "You should never
    // call blocking primitives on an actor or in async code." The cooperative thread pool
    // has ~N threads; blocking even one risks deadlock. Mutex is for sync multi-thread
    // state; ours is asynchronous.
    //
    // Fix: per-session async serialization via a Task chain. Each `withSessionLock` call
    // enqueues a new Task that awaits the prior Task for the same session name before
    // executing its body. Operations on different sessions don't block each other.
    //
    // Cancel-then-queue on user gestures: `signOut` and `signIn` call
    // `inFlightRefresh[name]?.cancel()` *before* taking the lock so the refresh's
    // network call unwinds quickly with CancellationError and the lock becomes available.
    // Serial semantics still hold; user-driven actions don't wait for doomed network calls.
    //
    // Apple-canonical pattern: Swift Forums "concurrency-safe-lock" thread + WWDC21 both
    // arrive here. Apple does not ship a built-in AsyncMutex; Task chain is the documented
    // approach.

    func withSessionLock<T: Sendable>(
        _ sessionName: String,
        _ body: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let prior = sessionLocks[sessionName]
        let work = Task<T, Error> {
            _ = await prior?.value
            return try await body()
        }
        // Store a Void-typed wrapper so the dictionary stays [String: Task<Void, Never>]
        // (the prior-await shape requires `Never` error, and callers that don't care about
        // the result shouldn't need T to be erased up the chain).
        sessionLocks[sessionName] = Task { _ = try? await work.value }
        // Propagate cancellation: if the calling Task is cancelled while we await `work`,
        // cancel `work` so the body's cooperative cancellation points unwind promptly.
        // Apple: Swift/withTaskCancellationHandler(operation:onCancel:)
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}
