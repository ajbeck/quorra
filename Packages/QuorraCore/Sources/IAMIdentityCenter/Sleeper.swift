import Foundation

/// A deterministic-test-friendly time source for the device-flow polling loop.
///
/// Production uses `WallClockSleeper` which delegates to `Date()` and `Task.sleep(for:)`.
/// Tests inject a controllable mock.
///
/// **A2 addition (D19):** `sleep(until:)` lets the expiration and refresh timers schedule
/// against a wall-clock deadline without requiring a `ContinuousClock` type parameter
/// on the actor. `WallClockSleeper` delegates to `Task.sleep(for:)` which uses
/// `ContinuousClock` internally, preserving sleep-through-system-sleep semantics.
/// `MockSleeper` jumps `currentTime` to the deadline so tests can advance synthetic time
/// to any future point without waiting real seconds.
public protocol Sleeper: Sendable {
    /// The current "now" — used for wall-clock deadline checks during polling.
    var now: Date { get async }

    /// Suspend for the given interval.
    func sleep(for interval: TimeInterval) async throws

    /// Suspend until the given wall-clock deadline (A2 — D19).
    ///
    /// Conformers must throw `CancellationError` when the enclosing `Task` is cancelled.
    func sleep(until deadline: Date) async throws
}

public struct WallClockSleeper: Sleeper {
    public init() {}
    public var now: Date { Date() }
    public func sleep(for interval: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(interval))
    }

    /// Delegates to `Task.sleep(for:)` using `ContinuousClock` under the hood — sleep
    /// accumulates even while the system is sleeping, so the timer fires correctly after
    /// a Mac wakes from sleep. Apple: Swift/Task/sleep(for:tolerance:clock:)
    public func sleep(until deadline: Date) async throws {
        let interval = deadline.timeIntervalSinceNow
        guard interval > 0 else { return }
        try await Task.sleep(for: .seconds(interval))
    }
}
