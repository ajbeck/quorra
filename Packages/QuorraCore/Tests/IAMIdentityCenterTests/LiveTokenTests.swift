import Testing
import Foundation
@testable import IAMIdentityCenter

extension IAMIdentityCenterTestSuite {
@Suite("liveToken (D10, D12)", .serialized, .timeLimit(.minutes(1)))
struct LiveTokenTests {

    // MARK: - Helpers

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
        originalLifetime: TimeInterval = 8 * 3600,
        sessionName: String = "s"
    ) async throws {
        try await keychain.writeRecord(
            StoredSSOToken(
                accessToken: "at",
                expiresAt: expiresAt,
                refreshToken: refreshToken,
                issuedAt: expiresAt.addingTimeInterval(-originalLifetime),
                region: "us-east-1",
                sessionName: sessionName
            ),
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: sessionName
        )
    }

    private func seedOIDCClient(
        keychain: InMemoryKeychainStore,
        region: String = "us-east-1"
    ) async throws {
        try await keychain.writeRecord(
            StoredOIDCClient(
                clientId: "cid",
                clientSecret: "cs",
                issuedAt: Date(),
                secretExpiresAt: Date().addingTimeInterval(90 * 24 * 60 * 60),
                region: region,
                scopes: ["sso:account:access"]
            ),
            service: IdentityCenterService.ServiceConstants.oidcClientService,
            account: region
        )
    }

    // MARK: - D12: Outside skew window — return immediately

    @Test("liveToken returns current token when outside its adaptive refresh window")
    func outsideSkewWindowReturnsCurrentToken() async throws {
        let keychain = InMemoryKeychainStore()
        // expiresAt is 2 hours out — well outside the 5-minute skew window
        let expiresAt = Date().addingTimeInterval(2 * 3600)
        try await seedToken(keychain: keychain, expiresAt: expiresAt)

        let service = makeService(keychain: keychain)
        let token = try await service.liveToken(forSession: "s")

        #expect(token.accessToken == "at")
        // No refresh should have been triggered; no in-flight tasks
        let inFlight = await service.inFlightRefresh["s"]
        #expect(inFlight == nil)
    }

    @Test("A five-minute token remains usable with more than ten percent of its lifetime left")
    func shortLifetimeOutsideAdaptiveWindowReturnsCurrentToken() async throws {
        let keychain = InMemoryKeychainStore()
        let expiresAt = Date().addingTimeInterval(40)
        try await seedToken(
            keychain: keychain,
            expiresAt: expiresAt,
            originalLifetime: 5 * 60
        )

        let service = makeService(keychain: keychain)
        let token = try await service.liveToken(forSession: "s")

        #expect(token.accessToken == "at")
    }

    // MARK: - D12: Inside skew window — inline refresh

    @Test("liveToken triggers inline refresh when inside its adaptive refresh window")
    func insideSkewWindowTriggersRefresh() async throws {
        let keychain = InMemoryKeychainStore()
        // expiresAt is 3 minutes out — inside the 5-minute skew window
        let expiresAt = Date().addingTimeInterval(3 * 60)
        try await seedToken(keychain: keychain, expiresAt: expiresAt, refreshToken: "rt")
        try await seedOIDCClient(keychain: keychain)

        let stub = StubOIDCRequesting()
        await stub.setNextRefreshResult(.success(makeDefaultSSOToken(accessToken: "new-at", refreshToken: "new-rt", sessionName: "s")))

        let service = makeService(keychain: keychain, stub: stub)
        let token = try await service.liveToken(forSession: "s")

        // The inline refresh should have completed and returned the NEW token
        #expect(token.accessToken == "new-at")
    }

    @Test("A five-minute token refreshes inside its final thirty seconds")
    func shortLifetimeInsideAdaptiveWindowTriggersRefresh() async throws {
        let keychain = InMemoryKeychainStore()
        let expiresAt = Date().addingTimeInterval(20)
        try await seedToken(
            keychain: keychain,
            expiresAt: expiresAt,
            refreshToken: "rt",
            originalLifetime: 5 * 60
        )
        try await seedOIDCClient(keychain: keychain)

        let stub = StubOIDCRequesting()
        await stub.setNextRefreshResult(.success(makeDefaultSSOToken(
            accessToken: "short-lived-refreshed-at",
            refreshToken: "rt",
            sessionName: "s"
        )))

        let service = makeService(keychain: keychain, stub: stub)
        let token = try await service.liveToken(forSession: "s")

        #expect(token.accessToken == "short-lived-refreshed-at")
        #expect(await stub.refreshCallCount == 1)
    }

    // MARK: - D12: Past expiry with canRefresh: true — inline refresh

    @Test("liveToken triggers inline refresh when token is past expiresAt and canRefresh: true")
    func pastExpiryWithRefreshTokenTriggersRefresh() async throws {
        let keychain = InMemoryKeychainStore()
        // expiresAt is 60 seconds IN THE PAST
        let expiresAt = Date().addingTimeInterval(-60)
        try await seedToken(keychain: keychain, expiresAt: expiresAt, refreshToken: "rt")
        try await seedOIDCClient(keychain: keychain)

        let stub = StubOIDCRequesting()
        await stub.setNextRefreshResult(.success(makeDefaultSSOToken(accessToken: "refreshed-at", refreshToken: "rt", sessionName: "s")))

        let service = makeService(keychain: keychain, stub: stub)
        let token = try await service.liveToken(forSession: "s")

        #expect(token.accessToken == "refreshed-at")
    }

    // MARK: - D12: Past expiry with canRefresh: false — throws .tokenExpired

    @Test("liveToken throws .tokenExpired when token is expired and has no refresh token")
    func pastExpiryNoRefreshThrowsTokenExpired() async throws {
        let keychain = InMemoryKeychainStore()
        let expiresAt = Date().addingTimeInterval(-60)
        // No refresh token
        try await seedToken(keychain: keychain, expiresAt: expiresAt, refreshToken: nil)

        let service = makeService(keychain: keychain)

        do {
            _ = try await service.liveToken(forSession: "s")
            Issue.record("Expected .tokenExpired to be thrown")
        } catch IAMIdentityCenterError.tokenExpired {
            // expected
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    // MARK: - D12: Not signed in — throws .notSignedIn

    @Test("liveToken throws .notSignedIn when no Keychain record exists")
    func notSignedInThrowsNotSignedIn() async throws {
        // Empty keychain — no token seeded
        let service = makeService()

        do {
            _ = try await service.liveToken(forSession: "s")
            Issue.record("Expected .notSignedIn to be thrown")
        } catch IAMIdentityCenterError.notSignedIn {
            // expected
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    // MARK: - D12: Concurrent callers coalesce via inFlightRefresh

    @Test("Concurrent liveToken calls coalesce — only one refresh call is made")
    func concurrentLiveTokenCallsCoalesce() async throws {
        let keychain = InMemoryKeychainStore()
        // Token inside the skew window
        let expiresAt = Date().addingTimeInterval(3 * 60)
        try await seedToken(keychain: keychain, expiresAt: expiresAt, refreshToken: "rt")
        try await seedOIDCClient(keychain: keychain)

        // Coalescing is driven by the actor's keychain-read suspension in performLiveToken,
        // not by network latency, so an instant stub result still exercises single-flight.
        let stub = StubOIDCRequesting()
        await stub.setNextRefreshResult(.success(makeDefaultSSOToken(accessToken: "coalesced-at", refreshToken: "rt", sessionName: "s")))

        let service = makeService(keychain: keychain, stub: stub)

        // Fire two concurrent liveToken calls
        async let t1 = service.liveToken(forSession: "s")
        async let t2 = service.liveToken(forSession: "s")

        let (tok1, tok2) = try await (t1, t2)

        // Both should succeed and return the refreshed token
        #expect(tok1.accessToken == "coalesced-at")
        #expect(tok2.accessToken == "coalesced-at")

        // Only ONE refresh should have gone out (D12 coalescing)
        #expect(await stub.refreshCallCount == 1)
    }

    // MARK: - D12: refreshNow coalesces with in-flight refresh

    @Test("refreshNow coalesces with an already-in-flight refresh instead of starting a second")
    func refreshNowCoalesces() async throws {
        let keychain = InMemoryKeychainStore()
        let expiresAt = Date().addingTimeInterval(3 * 60)
        try await seedToken(keychain: keychain, expiresAt: expiresAt, refreshToken: "rt")
        try await seedOIDCClient(keychain: keychain)

        let stub = StubOIDCRequesting()
        await stub.setNextRefreshResult(.success(makeDefaultSSOToken(accessToken: "coalesced-now", refreshToken: "rt", sessionName: "s")))

        let service = makeService(keychain: keychain, stub: stub)

        async let t1 = service.liveToken(forSession: "s")
        async let t2 = service.refreshNow(sessionName: "s")

        let (tok1, tok2) = try await (t1, t2)

        #expect(tok1.accessToken == "coalesced-now")
        #expect(tok2.accessToken == "coalesced-now")

        #expect(await stub.refreshCallCount == 1)
    }

    // MARK: - D14: liveToken propagates terminal refresh error

    @Test("liveToken throws .refreshTokenRejected when AWS returns invalid_grant (terminal)")
    func liveTokenPropagatesTerminalRefreshError() async throws {
        let keychain = InMemoryKeychainStore()
        // Inside skew so refresh will be triggered
        let expiresAt = Date().addingTimeInterval(3 * 60)
        try await seedToken(keychain: keychain, expiresAt: expiresAt, refreshToken: "bad-rt")
        try await seedOIDCClient(keychain: keychain)

        // The SDK adapter remaps a rejected refresh token (invalid_grant) to .refreshTokenRejected;
        // the stub stands in for that adapter output.
        let stub = StubOIDCRequesting()
        await stub.setNextRefreshResult(.failure(IAMIdentityCenterError.refreshTokenRejected))

        let service = makeService(keychain: keychain, stub: stub)

        do {
            _ = try await service.liveToken(forSession: "s")
            Issue.record("Expected .refreshTokenRejected to be thrown")
        } catch IAMIdentityCenterError.refreshTokenRejected {
            // expected
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    // MARK: - Keychain written with new token on success

    @Test("Successful liveToken refresh writes new token to Keychain")
    func successfulRefreshWritesNewTokenToKeychain() async throws {
        let keychain = InMemoryKeychainStore()
        let expiresAt = Date().addingTimeInterval(3 * 60)
        try await seedToken(keychain: keychain, expiresAt: expiresAt, refreshToken: "rt")
        try await seedOIDCClient(keychain: keychain)

        let stub = StubOIDCRequesting()
        await stub.setNextRefreshResult(.success(makeDefaultSSOToken(accessToken: "written-at", refreshToken: "written-rt", sessionName: "s")))

        let service = makeService(keychain: keychain, stub: stub)
        _ = try await service.liveToken(forSession: "s")

        // Read back from keychain to verify write happened
        let stored = try await keychain.readRecord(
            StoredSSOToken.self,
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: "s"
        )
        #expect(stored.accessToken == "written-at")
        #expect(stored.refreshToken == "written-rt")
    }
}
}
