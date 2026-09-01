import Foundation
import Testing
@testable import QuorraAppLogic

@Suite("Expiration countdown intervals")
struct ExpirationCountdownTests {
    @Test func futureDeadlineProducesValidInterval() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let expiresAt = now.addingTimeInterval(60)

        let interval = try #require(ExpirationCountdown.interval(until: expiresAt, now: now))

        #expect(interval.lowerBound == now)
        #expect(interval.upperBound == expiresAt)
    }

    @Test func currentOrPastDeadlineProducesNoInterval() {
        let now = Date(timeIntervalSince1970: 1_000)

        #expect(ExpirationCountdown.interval(until: now, now: now) == nil)
        #expect(ExpirationCountdown.interval(until: now.addingTimeInterval(-1), now: now) == nil)
    }
}
