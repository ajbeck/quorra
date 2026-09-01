import Foundation
import Testing
@testable import IAMIdentityCenter

extension IAMIdentityCenterTestSuite {
@Suite("Adaptive refresh timing")
struct RefreshTimingTests {

    @Test("Refresh skew is ten percent of lifetime with a five-minute ceiling")
    func adaptiveSkewMatrix() {
        let issuedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let cases: [(lifetime: TimeInterval, expectedSkew: TimeInterval)] = [
            (8 * 3600, 300),
            (3600, 300),
            (30 * 60, 180),
            (10 * 60, 60),
            (5 * 60, 30),
            (60, 6),
        ]

        for testCase in cases {
            let expiresAt = issuedAt.addingTimeInterval(testCase.lifetime)
            let skew = IdentityCenterService.ServiceConstants.refreshSkew(
                issuedAt: issuedAt,
                expiresAt: expiresAt
            )
            #expect(skew == testCase.expectedSkew)
        }
    }

    @Test("Invalid and zero lifetimes have no pre-expiration skew")
    func nonPositiveLifetimeHasZeroSkew() {
        let issuedAt = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(IdentityCenterService.ServiceConstants.refreshSkew(
            issuedAt: issuedAt,
            expiresAt: issuedAt
        ) == 0)
        #expect(IdentityCenterService.ServiceConstants.refreshSkew(
            issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(-60)
        ) == 0)
    }

    @Test("Refresh deadline is derived from the original lifetime")
    func refreshDeadlineUsesIssuedAt() {
        let issuedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let expiresAt = issuedAt.addingTimeInterval(5 * 60)
        let expected = expiresAt.addingTimeInterval(-30)

        let deadline = IdentityCenterService.ServiceConstants.refreshDeadline(
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )

        #expect(deadline == expected)
    }
}
}
