import Foundation

/// A deterministic-test-friendly time source for the device-flow polling loop.
///
/// Production uses `WallClockSleeper` which delegates to `Date()` and `Task.sleep(for:)`.
/// Tests inject a controllable mock.
public protocol Sleeper: Sendable {
    /// The current "now" — used for wall-clock deadline checks during polling.
    var now: Date { get async }

    /// Suspend for the given interval.
    func sleep(for interval: TimeInterval) async throws
}

public struct WallClockSleeper: Sleeper {
    public init() {}
    public var now: Date { Date() }
    public func sleep(for interval: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(interval))
    }
}
