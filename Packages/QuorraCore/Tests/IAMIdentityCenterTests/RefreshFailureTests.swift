import Testing
import Foundation
@testable import IAMIdentityCenter

extension IAMIdentityCenterTestSuite {
@Suite("Refresh failure handling (D14)", .serialized, .timeLimit(.minutes(1)))
struct RefreshFailureTests {

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

    private func seedOIDCClient(keychain: InMemoryKeychainStore, region: String = "us-east-1") async throws {
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

    // Reads the stored token back from the in-memory keychain
    private func readToken(keychain: InMemoryKeychainStore, sessionName: String = "s") async throws -> StoredSSOToken {
        try await keychain.readRecord(
            StoredSSOToken.self,
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: sessionName
        )
    }

    // MARK: - Terminal bucket: nils refreshToken in Keychain, emits .refreshFailed, cancels T_refresh
    //
    // `invalid_grant` → .refreshTokenRejected and `invalid_client` → .refreshClientInvalid exercise
    // the same nil-wipe code path. A single parameterized test covers both error codes plus
    // the timer-cancel and event assertions that would otherwise be separate tests.

    @Test(
        "Terminal failure nils refreshToken in Keychain, cancels T_refresh, emits .refreshFailed",
        arguments: [
            ("invalid_grant",  IAMIdentityCenterError.refreshTokenRejected),
            ("invalid_client", IAMIdentityCenterError.refreshClientInvalid),
        ]
    )
    func terminalFailureNilsRefreshToken(awsError: String, expectedError: IAMIdentityCenterError) async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        // Inside skew so liveToken triggers inline refresh
        let expiresAt = Date().addingTimeInterval(3 * 60)
        try await seedToken(keychain: keychain, expiresAt: expiresAt, refreshToken: "rt")
        try await seedOIDCClient(keychain: keychain)

        try StubURLProtocol.registerOAuthError(urlSubstring: "/token", statusCode: 400, error: awsError)

        let service = makeService(keychain: keychain)

        // Collect events for the .refreshFailed assertion below
        let collector = EventCollector()
        let eventTask = Task {
            for await event in service.events {
                await collector.append(event)
            }
        }
        defer { eventTask.cancel() }

        // Pre-seed a refresh timer so we can verify it gets cancelled
        let farFuture = Date().addingTimeInterval(2 * 3600)
        await service.scheduleRefresh(forSession: "s", expiresAt: farFuture)
        #expect(await service.refreshTimers["s"] != nil, "Precondition: refresh timer must be seeded")

        do {
            _ = try await service.liveToken(forSession: "s")
            Issue.record("Expected \(expectedError) to be thrown")
        } catch let err as IAMIdentityCenterError {
            #expect(err == expectedError)
        }

        // Keychain row: refreshToken nil, accessToken preserved
        let stored = try await readToken(keychain: keychain)
        #expect(stored.refreshToken == nil)
        #expect(stored.accessToken == "at")

        // T_refresh cancelled after terminal failure
        #expect(await service.refreshTimers["s"] == nil)

        // .refreshFailed event emitted
        await Task.yield()
        let events = await collector.events
        #expect(events.contains { if case .refreshFailed(let n) = $0, n == "s" { return true }; return false })
    }

    // MARK: - Transient bucket: network error leaves Keychain unchanged

    @Test("Network error leaves Keychain refresh token intact (transient — no terminal wipe)")
    func networkErrorLeavesKeychainUnchanged() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let expiresAt = Date().addingTimeInterval(3 * 60)
        try await seedToken(keychain: keychain, expiresAt: expiresAt, refreshToken: "rt")
        try await seedOIDCClient(keychain: keychain)

        StubURLProtocol.registerNetworkFailure(urlSubstring: "/token")

        let service = makeService(keychain: keychain)
        _ = try? await service.liveToken(forSession: "s")

        let stored = try await readToken(keychain: keychain)
        // Transient failure: refresh token must NOT have been wiped
        #expect(stored.refreshToken == "rt")
    }

    @Test("Network error throws .network (transient) from liveToken")
    func networkErrorThrowsNetworkError() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let expiresAt = Date().addingTimeInterval(3 * 60)
        try await seedToken(keychain: keychain, expiresAt: expiresAt, refreshToken: "rt")
        try await seedOIDCClient(keychain: keychain)

        StubURLProtocol.registerNetworkFailure(urlSubstring: "/token")

        let service = makeService(keychain: keychain)
        do {
            _ = try await service.liveToken(forSession: "s")
            Issue.record("Expected .network to be thrown")
        } catch IAMIdentityCenterError.network {
            // expected
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    // MARK: - Transient bucket: 5xx leaves Keychain unchanged

    @Test("5xx error leaves Keychain refresh token intact (transient)")
    func serverErrorLeavesKeychainUnchanged() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let expiresAt = Date().addingTimeInterval(3 * 60)
        try await seedToken(keychain: keychain, expiresAt: expiresAt, refreshToken: "rt")
        try await seedOIDCClient(keychain: keychain)

        StubURLProtocol.register5xxError(urlSubstring: "/token")

        let service = makeService(keychain: keychain)
        _ = try? await service.liveToken(forSession: "s")

        let stored = try await readToken(keychain: keychain)
        #expect(stored.refreshToken == "rt")
    }

    // MARK: - No auto-retry

    @Test("No auto-retry on transient failure — exactly one network call is made")
    func noAutoRetryOnTransientFailure() async throws {
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
            // Simulate a transient 503
            let url = URL(string: "https://oidc.us-east-1.amazonaws.com/token")!
            let response = HTTPURLResponse(url: url, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (Data(), response)
        }

        let service = makeService(keychain: keychain)
        _ = try? await service.liveToken(forSession: "s")

        // Must be exactly 1 — no retry loop
        #expect(callCount == 1)
    }

    // MARK: - T_expire left running after failure

    @Test("Expiration timer continues running after a transient refresh failure")
    func expirationTimerRunsAfterTransientFailure() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let expiresAt = Date().addingTimeInterval(3 * 60)
        try await seedToken(keychain: keychain, expiresAt: expiresAt, refreshToken: "rt")
        try await seedOIDCClient(keychain: keychain)

        StubURLProtocol.registerNetworkFailure(urlSubstring: "/token")

        let service = makeService(keychain: keychain)
        // Seed expiration timer first
        await service.scheduleExpiration(forSession: "s", expiresAt: expiresAt)
        #expect(await service.expirationTimers["s"] != nil)

        _ = try? await service.liveToken(forSession: "s")

        // T_expire should still be running
        #expect(await service.expirationTimers["s"] != nil)
        // Tidy up
        await service.expirationTimers["s"]?.cancel()
    }
}
}
