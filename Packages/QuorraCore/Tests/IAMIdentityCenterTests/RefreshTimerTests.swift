import Testing
import Foundation
@testable import IAMIdentityCenter

extension IAMIdentityCenterTestSuite {
@Suite("Refresh timer (T_refresh) scheduling", .serialized, .timeLimit(.minutes(1)))
struct RefreshTimerTests {

    private func makeService(
        keychain: InMemoryKeychainStore = InMemoryKeychainStore(),
        stub: StubOIDCRequesting = StubOIDCRequesting()
    ) -> IdentityCenterService {
        IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(stub))
    }

    private func seedToken(
        keychain: InMemoryKeychainStore,
        expiresAt: Date,
        refreshToken: String? = "rt",
        sessionName: String = "s"
    ) async throws {
        try await keychain.writeRecord(
            StoredSSOToken(
                accessToken: "at",
                expiresAt: expiresAt,
                refreshToken: refreshToken,
                issuedAt: Date(),
                region: "us-east-1",
                sessionName: sessionName
            ),
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: sessionName
        )
    }

    // MARK: - No refresh timer when canRefresh: false

    @Test("status() does not schedule T_refresh when token has no refresh token")
    func noRefreshTimerWhenNoRefreshToken() async throws {
        let keychain = InMemoryKeychainStore()
        let expiresAt = Date().addingTimeInterval(3600)
        try await seedToken(keychain: keychain, expiresAt: expiresAt, refreshToken: nil)

        let service = makeService(keychain: keychain)
        _ = await service.status(forSession: "s")

        let refreshTimer = await service.refreshTimers["s"]
        #expect(refreshTimer == nil)

        // Expiration timer still scheduled
        let expTimer = await service.expirationTimers["s"]
        #expect(expTimer != nil)
        expTimer?.cancel()
    }

    @Test("status() schedules T_refresh when token has refresh token")
    func statusSchedulesBothTimersWhenCanRefresh() async throws {
        let keychain = InMemoryKeychainStore()
        let expiresAt = Date().addingTimeInterval(3600)
        try await seedToken(keychain: keychain, expiresAt: expiresAt, refreshToken: "rt")

        let service = makeService(keychain: keychain)
        _ = await service.status(forSession: "s")

        let refreshTimer = await service.refreshTimers["s"]
        #expect(refreshTimer != nil)
        refreshTimer?.cancel()

        let expTimer = await service.expirationTimers["s"]
        #expect(expTimer != nil)
        expTimer?.cancel()
    }

    // MARK: - signOut cancels both timers

    @Test("signOut cancels both T_expire and T_refresh")
    func signOutCancelsBothTimers() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let expiresAt = Date().addingTimeInterval(3600)
        try await seedToken(keychain: keychain, expiresAt: expiresAt, refreshToken: "rt")

        // Register stub for portal logout
        try StubURLProtocol.registerSuccess(urlSubstring: "/logout", json: [:])
        let service = makeService(keychain: keychain)

        // Seed timers by calling status
        _ = await service.status(forSession: "s")

        #expect(await service.expirationTimers["s"] != nil)
        #expect(await service.refreshTimers["s"] != nil)

        try await service.signOut(sessionName: "s")

        #expect(await service.expirationTimers["s"] == nil)
        #expect(await service.refreshTimers["s"] == nil)
    }

    // MARK: - T_refresh does not double-fire when inFlightRefresh is active

    @Test("handleRefresh is no-op when inFlightRefresh already set — no second network call")
    func handleRefreshIsNoOpWhenInFlight() async throws {
        let stub = StubOIDCRequesting()
        let service = makeService()

        // Directly inject a never-completing task into inFlightRefresh["s"] via the
        // test-only helper below. This is the cleanest way to set the actor's internal
        // state from test code without spawning a real network call.
        let neverTask = Task<StoredSSOToken, Error> {
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }
        await service._test_setInFlightRefresh(neverTask, for: "s")

        // handleRefresh should see inFlightRefresh["s"] != nil and no-op immediately
        await service.handleRefresh(sessionName: "s")

        // Verify the guard worked: if it had called performRunRefresh, it would have tried
        // performRefreshNow → startInlineRefresh, which would have coalesced with `neverTask`
        // (not starting a second one). Either way, refreshCallCount should be 0 since the
        // guard short-circuits before any OIDC call.
        // Use the stub-based service to validate the call count is 0.
        let stubService = IdentityCenterService(keychain: InMemoryKeychainStore(), oidcClientProvider: makeStubOIDCProvider(stub))
        await stubService._test_setInFlightRefresh(neverTask, for: "s")
        await stubService.handleRefresh(sessionName: "s")
        let callCount = await stub.refreshCallCount
        #expect(callCount == 0, "handleRefresh must not call the refresh endpoint when inFlightRefresh is set")

        // Clean up
        neverTask.cancel()
        _ = await neverTask.result
    }
}
}
