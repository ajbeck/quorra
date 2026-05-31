#if DEBUG
import Foundation
import IAMIdentityCenter

/// Inert `IdentityCenterServicing` conformer for SwiftUI previews and tests where the
/// service shouldn't actually do anything. `signIn` traps if called — previews that need
/// to exercise sign-in should seed model state directly via the `seed*ForTesting` helpers.
struct PreviewIdentityCenterService: IdentityCenterServicing {
    nonisolated let events: AsyncStream<AuthEvent> = AsyncStream.makeStream(of: AuthEvent.self).stream

    @concurrent
    func signIn(
        sessionName: String,
        startUrl: URL,
        region: String,
        scopes: [String],
        clientName: String,
        verificationHandler: @escaping @concurrent @Sendable (DeviceVerification) async -> Void
    ) async throws -> StoredSSOToken {
        fatalError("PreviewIdentityCenterService.signIn should not be called in previews — seed model state directly")
    }

    func cancelSignIn(sessionName: String) async {}

    @concurrent
    func status(forSession sessionName: String) async -> SessionAuthStatus { .signedOut }

    @concurrent
    func signOut(sessionName: String) async throws {}

    @concurrent
    func liveToken(forSession sessionName: String) async throws -> StoredSSOToken {
        throw IAMIdentityCenterError.notSignedIn
    }

    @concurrent
    func refreshNow(sessionName: String) async throws -> StoredSSOToken {
        throw IAMIdentityCenterError.notSignedIn
    }

    @concurrent
    func liveCredentials(
        forSession sessionName: String,
        accountId: String,
        roleName: String,
        region: String
    ) async throws -> RoleCredentials {
        RoleCredentials(
            accessKeyId: "ASIA00000000EXMPL",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            sessionToken: "IQoJb3JpZ2luX2VjEOr//////////wEaCXVzLWVhc3QtMiJIMEYCIQC-example-token",
            expiresAt: Date().addingTimeInterval(6 * 3600 + 12 * 60),
            accountId: accountId,
            roleName: roleName,
            region: region,
            sessionName: sessionName,
            issuedAt: Date().addingTimeInterval(-48 * 60)
        )
    }

    @concurrent
    func status(
        forProfile sessionName: String,
        accountId: String,
        roleName: String
    ) async -> ProfileAuthStatus {
        .notSignedIn(sessionName: sessionName)
    }
}
#endif
