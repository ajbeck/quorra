import Testing
import Foundation
import IAMIdentityCenter

@Suite("SessionAuthStatus icon properties")
struct SessionStatusIconTests {
    @Test func statusCasesMapToExpectedIconState() {
        let cases: [(SessionAuthStatus, String, SessionAuthStatus.StatusEffect?, SessionAuthStatus.ForegroundRole, String)] = [
            (.signedOut, "key.icloud", nil, .secondary, "signed out"),
            (.signedIn(expiresAt: Date().addingTimeInterval(3600), canRefresh: false), "key.icloud.fill", nil, .green, "signed in"),
            (.expired(expiredAt: Date().addingTimeInterval(-60), canRefresh: false), "key.icloud", nil, .red, "token expired, sign in required"),
            (.expired(expiredAt: Date().addingTimeInterval(-60), canRefresh: true), "key.icloud.fill", nil, .green, "signed in, refreshing soon"),
            (.signingIn, "key.icloud.fill", .variableColor, .tint, "signing in"),
        ]

        for (status, symbol, effect, role, phraseFragment) in cases {
            #expect(status.symbolName == symbol)
            #expect(status.statusEffect == effect)
            #expect(status.foregroundRole == role)
            #expect(status.accessibilityPhrase.contains(phraseFragment))
        }
    }

    @Test func signedInAccessibilityUsesCoarseRemainingTime() {
        #expect(SessionAuthStatus.signedIn(expiresAt: Date().addingTimeInterval(2 * 3600), canRefresh: false).accessibilityPhrase.contains("hour"))
        #expect(SessionAuthStatus.signedIn(expiresAt: Date().addingTimeInterval(30 * 60), canRefresh: false).accessibilityPhrase.contains("minute"))
    }
}
