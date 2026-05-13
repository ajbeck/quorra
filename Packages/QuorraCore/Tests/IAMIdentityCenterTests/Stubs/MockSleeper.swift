import Foundation
@testable import IAMIdentityCenter

/// Deterministic sleeper for testing timeout and slow_down scenarios.
///
/// Test infrastructure only — actor-isolated for thread safety.
actor MockSleeper: Sleeper {
    private var currentTime: Date
    private var sleepers: [(deadline: Date, continuation: CheckedContinuation<Void, Error>)] = []
    private(set) var recordedSleeps: [TimeInterval] = []

    init(initialTime: Date = Date(timeIntervalSince1970: 0)) {
        self.currentTime = initialTime
    }

    var now: Date {
        get async {
            return currentTime
        }
    }

    func sleep(for interval: TimeInterval) async throws {
        recordedSleeps.append(interval)
        let deadline = currentTime.addingTimeInterval(interval)

        if currentTime >= deadline {
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            sleepers.append((deadline, continuation))
        }
    }

    /// Test API: advance now by `interval`; resume any sleepers whose deadline has passed.
    func advance(by interval: TimeInterval) {
        currentTime = currentTime.addingTimeInterval(interval)
        let snapshot = currentTime

        var resumed: [(deadline: Date, continuation: CheckedContinuation<Void, Error>)] = []
        var remaining: [(deadline: Date, continuation: CheckedContinuation<Void, Error>)] = []
        for s in sleepers {
            if s.deadline <= snapshot {
                resumed.append(s)
            } else {
                remaining.append(s)
            }
        }
        sleepers = remaining

        for c in resumed {
            c.continuation.resume()
        }
    }

    /// Test API: count of pending sleepers (for synchronization).
    var pendingSleeperCount: Int {
        get async {
            return sleepers.count
        }
    }
}
