import Testing
import Foundation
@testable import IAMIdentityCenter

extension IAMIdentityCenterTestSuite {
@Suite("liveToken (D10, D12)", .serialized, .timeLimit(.minutes(1)))
struct LiveTokenTests {

    // MARK: - Helpers

    private func makeService(
        keychain: InMemoryKeychainStore = InMemoryKeychainStore()
    ) -> IdentityCenterService {
        let oidcClient = OIDCClient(region: "us-east-1", urlSession: StubURLProtocol.makeSession())
        return IdentityCenterService(keychain: keychain, oidcClient: oidcClient)
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

    @Test("liveToken returns current token when outside skew window (> refreshSkew remaining)")
    func outsideSkewWindowReturnsCurrentToken() async throws {
        defer { StubURLProtocol.reset() }
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

    // MARK: - D12: Inside skew window — inline refresh

    @Test("liveToken triggers inline refresh when inside skew window (< refreshSkew remaining)")
    func insideSkewWindowTriggersRefresh() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        // expiresAt is 3 minutes out — inside the 5-minute skew window
        let expiresAt = Date().addingTimeInterval(3 * 60)
        try await seedToken(keychain: keychain, expiresAt: expiresAt, refreshToken: "rt")
        try await seedOIDCClient(keychain: keychain)

        // Stub the refresh endpoint
        try StubURLProtocol.registerSuccess(urlSubstring: "/token", json: [
            "accessToken": "new-at",
            "tokenType": "Bearer",
            "expiresIn": 28800,
            "refreshToken": "new-rt",
        ])

        let service = makeService(keychain: keychain)
        let token = try await service.liveToken(forSession: "s")

        // The inline refresh should have completed and returned the NEW token
        #expect(token.accessToken == "new-at")
    }

    // MARK: - D12: Past expiry with canRefresh: true — inline refresh

    @Test("liveToken triggers inline refresh when token is past expiresAt and canRefresh: true")
    func pastExpiryWithRefreshTokenTriggersRefresh() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        // expiresAt is 60 seconds IN THE PAST
        let expiresAt = Date().addingTimeInterval(-60)
        try await seedToken(keychain: keychain, expiresAt: expiresAt, refreshToken: "rt")
        try await seedOIDCClient(keychain: keychain)

        try StubURLProtocol.registerSuccess(urlSubstring: "/token", json: [
            "accessToken": "refreshed-at",
            "tokenType": "Bearer",
            "expiresIn": 28800,
        ])

        let service = makeService(keychain: keychain)
        let token = try await service.liveToken(forSession: "s")

        #expect(token.accessToken == "refreshed-at")
    }

    // MARK: - D12: Past expiry with canRefresh: false — throws .tokenExpired

    @Test("liveToken throws .tokenExpired when token is expired and has no refresh token")
    func pastExpiryNoRefreshThrowsTokenExpired() async throws {
        defer { StubURLProtocol.reset() }
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
        defer { StubURLProtocol.reset() }
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

    @Test("Concurrent liveToken calls coalesce — only one refresh network call is made")
    func concurrentLiveTokenCallsCoalesce() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        // Token inside the skew window
        let expiresAt = Date().addingTimeInterval(3 * 60)
        try await seedToken(keychain: keychain, expiresAt: expiresAt, refreshToken: "rt")
        try await seedOIDCClient(keychain: keychain)

        // Count how many times the /token endpoint was hit (synchronous — handler is not async)
        nonisolated(unsafe) var callCount = 0
        let lock = NSLock()

        StubURLProtocol.registerCustom(urlSubstring: "/token") { _ in
            lock.lock()
            callCount += 1
            lock.unlock()
            let data = try! JSONSerialization.data(withJSONObject: [
                "accessToken": "coalesced-at",
                "tokenType": "Bearer",
                "expiresIn": 28800,
            ])
            let url = URL(string: "https://oidc.us-east-1.amazonaws.com/token")!
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            return (data, response)
        }

        let service = makeService(keychain: keychain)

        // Fire two concurrent liveToken calls
        async let t1 = service.liveToken(forSession: "s")
        async let t2 = service.liveToken(forSession: "s")

        let (tok1, tok2) = try await (t1, t2)

        // Both should succeed and return the refreshed token
        #expect(tok1.accessToken == "coalesced-at")
        #expect(tok2.accessToken == "coalesced-at")

        // Only ONE network call should have gone out (D12 coalescing)
        #expect(callCount == 1)
    }

    // MARK: - D12: refreshNow coalesces with in-flight refresh

    @Test("refreshNow coalesces with an already-in-flight refresh instead of starting a second")
    func refreshNowCoalesces() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let expiresAt = Date().addingTimeInterval(3 * 60)
        try await seedToken(keychain: keychain, expiresAt: expiresAt, refreshToken: "rt")
        try await seedOIDCClient(keychain: keychain)

        nonisolated(unsafe) var callCount = 0
        let lock = NSLock()

        StubURLProtocol.registerCustom(urlSubstring: "/token") { _ in
            lock.lock()
            callCount += 1
            lock.unlock()
            let data = try! JSONSerialization.data(withJSONObject: [
                "accessToken": "coalesced-now",
                "tokenType": "Bearer",
                "expiresIn": 28800,
            ])
            let url = URL(string: "https://oidc.us-east-1.amazonaws.com/token")!
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            return (data, response)
        }

        let service = makeService(keychain: keychain)

        async let t1 = service.liveToken(forSession: "s")
        async let t2 = service.refreshNow(sessionName: "s")

        let (tok1, tok2) = try await (t1, t2)

        #expect(tok1.accessToken == "coalesced-now")
        #expect(tok2.accessToken == "coalesced-now")

        #expect(callCount == 1)
    }

    // MARK: - D14: liveToken propagates terminal refresh error

    @Test("liveToken throws .refreshTokenRejected when AWS returns invalid_grant (terminal)")
    func liveTokenPropagatesTerminalRefreshError() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        // Inside skew so refresh will be triggered
        let expiresAt = Date().addingTimeInterval(3 * 60)
        try await seedToken(keychain: keychain, expiresAt: expiresAt, refreshToken: "bad-rt")
        try await seedOIDCClient(keychain: keychain)

        try StubURLProtocol.registerOAuthError(urlSubstring: "/token", statusCode: 400, error: "invalid_grant")

        let service = makeService(keychain: keychain)

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
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let expiresAt = Date().addingTimeInterval(3 * 60)
        try await seedToken(keychain: keychain, expiresAt: expiresAt, refreshToken: "rt")
        try await seedOIDCClient(keychain: keychain)

        try StubURLProtocol.registerSuccess(urlSubstring: "/token", json: [
            "accessToken": "written-at",
            "tokenType": "Bearer",
            "expiresIn": 28800,
            "refreshToken": "written-rt",
        ])

        let service = makeService(keychain: keychain)
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
