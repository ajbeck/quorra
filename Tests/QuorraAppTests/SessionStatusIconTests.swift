import Testing
import Foundation
import IAMIdentityCenter

/// Property tests for `SessionAuthStatus` sidebar icon properties (D4).
///
/// Verifies that each status case maps to the expected `symbolName`, `statusEffect`,
/// `foregroundRole`, and `accessibilityPhrase` values. These properties are the primary
/// contract between the model layer and `SessionStatusIcon` / `SessionRow`.
@Suite("SessionAuthStatus icon properties (D4)")
struct SessionStatusIconTests {

    // MARK: - signedOut

    @Test("signedOut: outline symbol, no effect, secondary color")
    func signedOutProperties() {
        let status = SessionAuthStatus.signedOut
        #expect(status.symbolName == "key.icloud")
        #expect(status.statusEffect == nil)
        #expect(status.foregroundRole == .secondary)
        #expect(status.accessibilityPhrase == "signed out")
    }

    // MARK: - signedIn

    @Test("signedIn: filled symbol, no effect, green color")
    func signedInProperties() {
        let expiresAt = Date().addingTimeInterval(3600)
        let status = SessionAuthStatus.signedIn(expiresAt: expiresAt, canRefresh: false)
        #expect(status.symbolName == "key.icloud.fill")
        #expect(status.statusEffect == nil)
        #expect(status.foregroundRole == .green)
    }

    @Test("signedIn accessibilityPhrase includes hours when > 1 hour remaining")
    func signedInAccessibilityPhraseHours() {
        let expiresAt = Date().addingTimeInterval(2 * 3600) // 2 hours
        let status = SessionAuthStatus.signedIn(expiresAt: expiresAt, canRefresh: false)
        #expect(status.accessibilityPhrase.contains("hour"))
    }

    @Test("signedIn accessibilityPhrase includes minutes when < 1 hour remaining")
    func signedInAccessibilityPhraseMinutes() {
        let expiresAt = Date().addingTimeInterval(30 * 60) // 30 minutes
        let status = SessionAuthStatus.signedIn(expiresAt: expiresAt, canRefresh: false)
        #expect(status.accessibilityPhrase.contains("minute"))
    }

    // MARK: - expired(canRefresh: false)

    @Test("expired(canRefresh:false): outline symbol, no effect, red color")
    func expiredNoRefreshProperties() {
        let expiredAt = Date().addingTimeInterval(-60)
        let status = SessionAuthStatus.expired(expiredAt: expiredAt, canRefresh: false)
        #expect(status.symbolName == "key.icloud")
        #expect(status.statusEffect == nil)
        #expect(status.foregroundRole == .red)
        #expect(status.accessibilityPhrase == "token expired, sign in required")
    }

    // MARK: - expired(canRefresh: true)

    @Test("expired(canRefresh:true): filled symbol, no effect, green color — renders like signedIn (D4)")
    func expiredCanRefreshProperties() {
        let expiredAt = Date().addingTimeInterval(-60)
        let status = SessionAuthStatus.expired(expiredAt: expiredAt, canRefresh: true)
        // Per D4: identical visual to signedIn — A2 silent refresh will heal
        #expect(status.symbolName == "key.icloud.fill")
        #expect(status.statusEffect == nil)
        #expect(status.foregroundRole == .green)
        #expect(status.accessibilityPhrase == "signed in, refreshing soon")
    }

    // MARK: - signingIn

    @Test("signingIn: filled symbol, variableColor effect, tint color")
    func signingInProperties() {
        let status = SessionAuthStatus.signingIn
        #expect(status.symbolName == "key.icloud.fill")
        #expect(status.statusEffect == .variableColor)
        #expect(status.foregroundRole == .tint)
        #expect(status.accessibilityPhrase == "signing in")
    }

    // MARK: - refreshing

    @Test("refreshing: filled symbol, pulse effect, green color")
    func refreshingProperties() {
        let status = SessionAuthStatus.refreshing
        #expect(status.symbolName == "key.icloud.fill")
        #expect(status.statusEffect == .pulse)
        #expect(status.foregroundRole == .green)
        #expect(status.accessibilityPhrase == "refreshing")
    }

    // MARK: - Exhaustive symbol shape rule

    @Test("Outline symbol = action needed; filled symbol = has token", arguments: [
        (SessionAuthStatus.signedOut, false),
        (SessionAuthStatus.signingIn, true),
        (SessionAuthStatus.refreshing, true),
        (SessionAuthStatus.signedIn(expiresAt: Date().addingTimeInterval(3600), canRefresh: false), true),
        (SessionAuthStatus.expired(expiredAt: Date().addingTimeInterval(-60), canRefresh: true), true),
        (SessionAuthStatus.expired(expiredAt: Date().addingTimeInterval(-60), canRefresh: false), false),
    ])
    func symbolShapeRule(status: SessionAuthStatus, expectFilled: Bool) {
        if expectFilled {
            #expect(status.symbolName.hasSuffix(".fill"), "Expected filled symbol for \(status), got \(status.symbolName)")
        } else {
            #expect(!status.symbolName.hasSuffix(".fill"), "Expected outline symbol for \(status), got \(status.symbolName)")
        }
    }
}
