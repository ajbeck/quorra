import Foundation
@testable import IAMIdentityCenter

/// Deterministic sleeper. `sleep(for:)` and `sleep(until:)` auto-advance the synthetic
/// clock and signal any `waitForNextSleep()` waiters; tests can act between timer firings
/// by awaiting `waitForNextSleep()` before the next advance.
///
/// `initialTime` defaults to `Date()` (not the Unix epoch) so synthetic `now` is comparable
/// to `verification.expiresAt`, which production code computes from `Date()`.
actor MockSleeper: Sleeper {
    private var currentTime: Date
    private(set) var recordedSleeps: [TimeInterval] = []
    private(set) var recordedDeadlines: [Date] = []
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

    /// Jumps `currentTime` to `deadline` (D19). Signal any `waitForNextSleep()` waiters,
    /// then yield once so cooperatively-cancelled tasks and test-side continuations run.
    func sleep(until deadline: Date) async throws {
        recordedDeadlines.append(deadline)
        // Jump synthetic time to the deadline so subsequent `now` reads reflect post-sleep state
        if deadline > currentTime {
            currentTime = deadline
        }

        let waiters = nextSleepWaiters
        nextSleepWaiters.removeAll()
        for waiter in waiters { waiter.resume() }

        await Task.yield()
        try Task.checkCancellation()
    }

    /// Suspends until the next `sleep(for:)` or `sleep(until:)` is called.
    func waitForNextSleep() async {
        await withCheckedContinuation { continuation in
            nextSleepWaiters.append(continuation)
        }
    }
}
