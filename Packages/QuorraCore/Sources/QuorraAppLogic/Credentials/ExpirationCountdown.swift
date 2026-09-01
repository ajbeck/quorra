import Foundation

public enum ExpirationCountdown {
    /// Returns a valid timer interval only while the deadline is in the future.
    ///
    /// `ClosedRange` traps when its lower bound follows its upper bound, so views
    /// must not construct `Date.now...expiresAt` after an expiration transition.
    public static func interval(
        until expiresAt: Date,
        now: Date = .now
    ) -> ClosedRange<Date>? {
        guard now < expiresAt else { return nil }
        return now...expiresAt
    }
}
