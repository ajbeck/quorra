import Foundation
import IAMIdentityCenter
import Testing
@testable import QuorraAppLogic

@Suite("Profile credential readiness")
struct ProfileCredentialReadinessTests {
    private func resolve(
        sessionName: String? = "acme",
        sessionStatus: SessionAuthStatus? = nil,
        profileStatus: ProfileAuthStatus? = nil,
        isSignInInFlight: Bool = false,
        isRoleRejected: Bool = false,
        hasRefreshFailure: Bool = false
    ) -> ProfileCredentialReadiness {
        ProfileCredentialReadiness.resolve(
            sessionName: sessionName,
            sessionStatus: sessionStatus,
            profileStatus: profileStatus,
            isSignInInFlight: isSignInInFlight,
            isRoleRejected: isRoleRejected,
            hasRefreshFailure: hasRefreshFailure
        )
    }

    private let soon = Date().addingTimeInterval(3600)
    private let earlier = Date().addingTimeInterval(-60)

    @Test func signedOutOrExpiredWithoutRefreshNeedsSignIn() {
        #expect(resolve(sessionStatus: .signedOut, profileStatus: .ready(expiresAt: soon)) == .needsSignIn(sessionName: "acme"))
        #expect(resolve(sessionStatus: .expired(expiredAt: earlier, canRefresh: false), profileStatus: .ready(expiresAt: soon)) == .needsSignIn(sessionName: "acme"))
    }

    @Test func expiredWithRefreshTokenStaysReadyUntilARefreshFails() {
        let expired = SessionAuthStatus.expired(expiredAt: earlier, canRefresh: true)
        #expect(resolve(sessionStatus: expired, profileStatus: .ready(expiresAt: soon)) == .ready)
        #expect(resolve(sessionStatus: expired, profileStatus: .ready(expiresAt: soon), hasRefreshFailure: true) == .needsSignIn(sessionName: "acme"))
    }

    @Test func profileStatusDecidesWhenTheSessionIsSignedIn() {
        let signedIn = SessionAuthStatus.signedIn(expiresAt: soon, canRefresh: true)
        #expect(resolve(sessionStatus: signedIn, profileStatus: nil) == .checking)
        #expect(resolve(sessionStatus: signedIn, profileStatus: .ready(expiresAt: nil)) == .ready)
        #expect(resolve(sessionStatus: nil, profileStatus: .signInExpired(sessionName: "acme")) == .needsSignIn(sessionName: "acme"))
        #expect(resolve(sessionStatus: nil, profileStatus: .notSignedIn(sessionName: "acme")) == .needsSignIn(sessionName: "acme"))
    }

    @Test func inFlightSignInAndRejectedRolesComeFirst() {
        #expect(resolve(sessionStatus: .signedOut, isSignInInFlight: true) == .signingIn)
        #expect(resolve(sessionStatus: .signingIn, profileStatus: .notSignedIn(sessionName: "acme")) == .signingIn)
        #expect(resolve(sessionStatus: .signedOut, isRoleRejected: true) == .unavailable)
        #expect(resolve(sessionName: nil, sessionStatus: .signedOut) == .unavailable)
    }

    @MainActor
    @Test func credentialsModelReadsItsOwnCaches() {
        let model = CredentialsModel(service: StubIdentityCenterService())
        let key = "acme:123456789012:Admin"
        model.seedStatusForTesting(.expired(expiredAt: earlier, canRefresh: true), sessionName: "acme")
        model.seedProfileStatusForTesting(.ready(expiresAt: soon), key: key)
        #expect(model.readiness(forSession: "acme", accountId: "123456789012", roleName: "Admin") == .ready)

        model.seedRefreshFailureForTesting(sessionName: "acme")
        #expect(model.readiness(forSession: "acme", accountId: "123456789012", roleName: "Admin") == .needsSignIn(sessionName: "acme"))
    }
}
