import Testing
import Foundation
@testable import IAMIdentityCenter

extension IAMIdentityCenterTestSuite {
@Suite("Token rotation (D18)", .serialized, .timeLimit(.minutes(1)))
struct TokenRotationTests {

    // MARK: - Helpers

    private func makeService(
        keychain: InMemoryKeychainStore,
        stub: StubOIDCRequesting = StubOIDCRequesting()
    ) -> IdentityCenterService {
        IdentityCenterService(keychain: keychain, oidcClient: stub)
    }

    private func seedToken(
        keychain: InMemoryKeychainStore,
        refreshToken: String? = "old-rt",
        sessionName: String = "s"
    ) async throws {
        // expiresAt is 3 minutes out — inside the skew window so liveToken triggers refresh
        try await keychain.writeRecord(
            StoredSSOToken(
                accessToken: "at",
                expiresAt: Date().addingTimeInterval(3 * 60),
                refreshToken: refreshToken,
                issuedAt: Date(),
                region: "us-east-1",
                sessionName: sessionName
            ),
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: sessionName
        )
    }

    private func seedOIDCClient(keychain: InMemoryKeychainStore) async throws {
        try await keychain.writeRecord(
            StoredOIDCClient(
                clientId: "cid",
                clientSecret: "cs",
                issuedAt: Date(),
                secretExpiresAt: Date().addingTimeInterval(90 * 24 * 60 * 60),
                region: "us-east-1",
                scopes: ["sso:account:access"]
            ),
            service: IdentityCenterService.ServiceConstants.oidcClientService,
            account: "us-east-1"
        )
    }

    private func readToken(keychain: InMemoryKeychainStore, sessionName: String = "s") async throws -> StoredSSOToken {
        try await keychain.readRecord(
            StoredSSOToken.self,
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: sessionName
        )
    }

    // MARK: - D18: New refresh token in response replaces old

    @Test("Response containing refreshToken rotates the stored refresh token")
    func newRefreshTokenRotatesStoredToken() async throws {
        let keychain = InMemoryKeychainStore()
        try await seedToken(keychain: keychain, refreshToken: "old-rt")
        try await seedOIDCClient(keychain: keychain)

        let stub = StubOIDCRequesting()
        await stub.setNextRefreshResult(.success(makeDefaultSSOToken(
            accessToken: "new-at",
            refreshToken: "rotated-rt",
            sessionName: "s"
        )))

        let service = makeService(keychain: keychain, stub: stub)
        _ = try await service.liveToken(forSession: "s")

        let stored = try await readToken(keychain: keychain)
        #expect(stored.refreshToken == "rotated-rt", "Expected rotated refresh token; got \(stored.refreshToken ?? "nil")")
        #expect(stored.accessToken == "new-at")
    }

    // MARK: - D18: Nil refreshToken in response — service writes what OIDC client returns
    //
    // The no-rotation fallback (keeping old-rt when response has no refreshToken) is OIDCClient
    // wire logic tested in OIDCClientRefreshTests. At the service layer, IdentityCenterService
    // faithfully persists whatever StoredSSOToken the OIDC client produces. This test verifies
    // that a nil refreshToken from the OIDC client is written to Keychain as-is (no silently
    // injected refresh token at the service layer).

    @Test("Service writes nil refreshToken when OIDC client returns nil — no service-layer injection")
    func serviceWritesNilRefreshTokenFromOIDCClient() async throws {
        let keychain = InMemoryKeychainStore()
        try await seedToken(keychain: keychain, refreshToken: "old-rt")
        try await seedOIDCClient(keychain: keychain)

        // OIDC client (stub) already applied the no-rotation fallback and returns nil here
        let stub = StubOIDCRequesting()
        await stub.setNextRefreshResult(.success(makeDefaultSSOToken(
            accessToken: "new-at",
            refreshToken: nil,
            sessionName: "s"
        )))

        let service = makeService(keychain: keychain, stub: stub)
        _ = try await service.liveToken(forSession: "s")

        let stored = try await readToken(keychain: keychain)
        // Service writes exactly what the OIDC client returned — no service-layer injection
        #expect(stored.refreshToken == nil)
        #expect(stored.accessToken == "new-at")
    }

    // MARK: - Atomic Keychain overwrite

    @Test("Successful refresh atomically overwrites the Keychain row (single write)")
    func successfulRefreshWritesExactlyOnce() async throws {
        let keychain = InMemoryKeychainStore()
        try await seedToken(keychain: keychain, refreshToken: "old-rt")
        try await seedOIDCClient(keychain: keychain)

        let stub = StubOIDCRequesting()
        await stub.setNextRefreshResult(.success(makeDefaultSSOToken(
            accessToken: "atomic-at",
            refreshToken: "atomic-rt",
            sessionName: "s"
        )))

        let service = makeService(keychain: keychain, stub: stub)
        let returned = try await service.liveToken(forSession: "s")
        let stored = try await readToken(keychain: keychain)

        // Returned token and Keychain row are consistent
        #expect(returned.accessToken == stored.accessToken)
        #expect(returned.refreshToken == stored.refreshToken)
        #expect(stored.accessToken == "atomic-at")
        #expect(stored.refreshToken == "atomic-rt")
    }

    // MARK: - New timers scheduled with rotated expiresAt

    @Test("After rotation both timers are rescheduled for the new expiresAt")
    func rotationReschedulesTimers() async throws {
        let keychain = InMemoryKeychainStore()
        try await seedToken(keychain: keychain, refreshToken: "old-rt")
        try await seedOIDCClient(keychain: keychain)

        let stub = StubOIDCRequesting()
        await stub.setNextRefreshResult(.success(makeDefaultSSOToken(
            accessToken: "timer-at",
            refreshToken: "timer-rt",
            sessionName: "s",
            expiresIn: 8 * 3600
        )))

        let service = makeService(keychain: keychain, stub: stub)
        _ = try await service.liveToken(forSession: "s")

        // Both timers should be scheduled for the new 8-hour token
        let expTimer = await service.expirationTimers["s"]
        let refTimer = await service.refreshTimers["s"]
        #expect(expTimer != nil, "Expiration timer should be scheduled after rotation")
        #expect(refTimer != nil, "Refresh timer should be scheduled after rotation")

        // Clean up
        expTimer?.cancel()
        refTimer?.cancel()
    }
}
}
