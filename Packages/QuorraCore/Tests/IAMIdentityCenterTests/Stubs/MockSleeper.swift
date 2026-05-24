import Foundation
@testable import IAMIdentityCenter

/// Deterministic sleeper. `sleep(for:)` and `sleep(until:)` auto-advance the synthetic
/// clock and signal waiters; tests can act between timer firings by awaiting
/// `waitForSleepCount(atLeast:)` before the next advance.
///
/// `initialTime` defaults to `Date()` (not the Unix epoch) so synthetic `now` is comparable
/// to `verification.expiresAt`, which production code computes from `Date()`.
actor MockSleeper: Sleeper {
    private var currentTime: Date
    private(set) var recordedSleeps: [TimeInterval] = []
    private(set) var recordedDeadlines: [Date] = []
    private var sleepCount = 0
    private var sleepWaiters: [(targetCount: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(initialTime: Date = Date()) {
        self.currentTime = initialTime
    }

    var now: Date {
        get async { currentTime }
    }

    func sleep(for interval: TimeInterval) async throws {
        recordedSleeps.append(interval)
        currentTime = currentTime.addingTimeInterval(interval)

        signalSleepWaiters()

        // Yield so cooperatively-cancelled tasks observe the cancellation and so any
        // test-side actions queued behind sleep-count waiters get a chance to run.
        await Task.yield()
        try Task.checkCancellation()
    }

    /// Jumps `currentTime` to `deadline` (D19). Signal any sleep waiters,
    /// then yield once so cooperatively-cancelled tasks and test-side continuations run.
    func sleep(until deadline: Date) async throws {
        recordedDeadlines.append(deadline)
        // Jump synthetic time to the deadline so subsequent `now` reads reflect post-sleep state
        if deadline > currentTime {
            currentTime = deadline
        }

        signalSleepWaiters()

        await Task.yield()
        try Task.checkCancellation()
    }

    /// Suspends until the next `sleep(for:)` or `sleep(until:)` is called.
    func waitForNextSleep() async {
        await waitForSleepCount(atLeast: sleepCount + 1)
    }

    /// Suspends until at least `targetCount` sleeps have been observed.
    func waitForSleepCount(atLeast targetCount: Int) async {
        guard sleepCount < targetCount else { return }

        await withCheckedContinuation { continuation in
            sleepWaiters.append((targetCount, continuation))
        }
    }

    private func signalSleepWaiters() {
        sleepCount += 1

        let readyWaiters = sleepWaiters.filter { $0.targetCount <= sleepCount }
        sleepWaiters.removeAll { $0.targetCount <= sleepCount }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
    }
}
