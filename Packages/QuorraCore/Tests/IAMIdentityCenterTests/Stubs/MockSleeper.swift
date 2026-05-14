import Foundation
@testable import IAMIdentityCenter

/// Deterministic sleeper. `sleep(for:)` auto-advances the synthetic clock and yields once;
/// `waitForNextSleep()` is a sync point for tests that need to act between iterations.
///
/// `initialTime` defaults to `Date()` (not the Unix epoch) so synthetic `now` is comparable
/// to `verification.expiresAt`, which production code computes from `Date()`.
actor MockSleeper: Sleeper {
    private var currentTime: Date
    private(set) var recordedSleeps: [TimeInterval] = []
    private var nextSleepWaiters: [CheckedContinuation<Void, Never>] = []

    init(initialTime: Date = Date()) {
        self.currentTime = initialTime
    }

    var now: Date {
        get async { currentTime }
    }

    func sleep(for interval: TimeInterval) async throws {
        recordedSleeps.append(interval)
        currentTime = currentTime.addingTimeInterval(interval)

        let waiters = nextSleepWaiters
        nextSleepWaiters.removeAll()
        for waiter in waiters { waiter.resume() }

        // Yield so cooperatively-cancelled tasks observe the cancellation and so any
        // test-side actions queued behind `waitForNextSleep()` get a chance to run.
        await Task.yield()
        try Task.checkCancellation()
    }

    /// Suspends until the next `sleep(for:)` is called.
    func waitForNextSleep() async {
        await withCheckedContinuation { continuation in
            nextSleepWaiters.append(continuation)
        }
    }
}
