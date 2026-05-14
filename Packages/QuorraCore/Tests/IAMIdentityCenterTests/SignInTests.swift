import Foundation
import Synchronization
import Testing
@testable import IAMIdentityCenter

actor VerificationCapture {
    var verification: DeviceVerification?

    func record(_ v: DeviceVerification) {
        verification = v
    }
}

/// Integration tests for `IdentityCenterService.signIn`.
///
/// Per Apple's testing pyramid (*"Testing"* docs): these are integration tests — they wire up
/// the actor, OIDC client (with URLProtocol stubs), an in-memory keychain store, and a
/// synthetic sleeper to assert end-to-end flow behavior. Per-endpoint request/response shape
/// and error mapping live in `OIDCClientTests`.
///
/// The suite carries a `.timeLimit` trait so any future regression that would have produced a
/// hang (e.g. an unbounded polling loop, a missing wake-up notification) surfaces as a
/// recorded test failure within the bound, not an indefinite session hang. Apple's
/// `Testing/TimeLimitTrait` is the documented mechanism for this.
extension IAMIdentityCenterTestSuite {
@Suite("IdentityCenterService.signIn", .serialized, .timeLimit(.minutes(1)))
struct SignInTests {

    // MARK: - Happy path

    @Test("Happy path returns token and persists it")
    func happyPath() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let oidcClient = OIDCClient(region: "us-east-1", urlSession: StubURLProtocol.makeSession())
        let service = IdentityCenterService(keychain: keychain, oidcClient: oidcClient, sleeper: MockSleeper())

        try registerStub(clientId: "test-client-id", clientSecret: "test-client-secret")
        try deviceAuthStub(expiresIn: 600, interval: 1)
        try StubURLProtocol.registerSuccess(urlSubstring: "/token", json: [
            "accessToken": "test-access-token",
            "tokenType": "Bearer",
            "expiresIn": 28800,
            "refreshToken": "test-refresh-token",
        ])

        let capture = VerificationCapture()
        let token = try await service.signIn(
            sessionName: "test-session",
            startUrl: URL(string: "https://example.awsapps.com/start")!,
            region: "us-east-1",
            scopes: ["sso:account:access"],
            verificationHandler: { await capture.record($0) }
        )

        #expect(token.accessToken == "test-access-token")
        #expect(token.refreshToken == "test-refresh-token")
        #expect(token.sessionName == "test-session")
        #expect(token.region == "us-east-1")
        #expect(await capture.verification?.userCode == "ABCD-1234")

        let persistedToken = try await keychain.readRecord(
            StoredSSOToken.self,
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: "test-session"
        )
        #expect(persistedToken.accessToken == "test-access-token")

        let persistedClient = try await keychain.readRecord(
            StoredOIDCClient.self,
            service: "dev.ajbeck.quorra.oidc-client",
            account: "us-east-1"
        )
        #expect(persistedClient.clientId == "test-client-id")

    }

    // MARK: - Slow down

    @Test("slow_down increases polling interval by 5s")
    func slowDown() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let oidcClient = OIDCClient(region: "us-east-1", urlSession: StubURLProtocol.makeSession())
        let sleeper = MockSleeper()
        let service = IdentityCenterService(keychain: keychain, oidcClient: oidcClient, sleeper: sleeper)

        try registerStub()
        try deviceAuthStub(expiresIn: 600, interval: 5)

        // First /token → slow_down; second /token → success.
        // URLProtocol callbacks fire on URLSession's internal queue; counter must be
        // synchronization-safe rather than `nonisolated(unsafe)`.
        let tokenCallCount = Mutex<Int>(0)
        StubURLProtocol.registerCustom(urlSubstring: "/token") { _ in
            let n = tokenCallCount.withLock { count -> Int in
                count += 1
                return count
            }
            return n == 1 ? oauthErrorResponse("slow_down") : tokenSuccessResponse()
        }

        let token = try await service.signIn(
            sessionName: "test-session",
            startUrl: URL(string: "https://example.awsapps.com/start")!,
            region: "us-east-1",
            scopes: ["sso:account:access"],
            verificationHandler: { _ in }
        )

        #expect(token.accessToken == "test-access-token")
        #expect(await sleeper.recordedSleeps == [5.0, 10.0])

    }

    // MARK: - Wall-clock timeout

    @Test("Wall-clock timeout throws .deviceFlowTimedOut")
    func wallClockTimeout() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let oidcClient = OIDCClient(region: "us-east-1", urlSession: StubURLProtocol.makeSession())
        let service = IdentityCenterService(keychain: keychain, oidcClient: oidcClient, sleeper: MockSleeper())

        try registerStub()
        try deviceAuthStub(expiresIn: 10, interval: 5)
        try StubURLProtocol.registerOAuthError(urlSubstring: "/token", error: "authorization_pending")

        do {
            _ = try await service.signIn(
                sessionName: "test-session",
                startUrl: URL(string: "https://example.awsapps.com/start")!,
                region: "us-east-1",
                scopes: ["sso:account:access"],
                verificationHandler: { _ in }
            )
            Issue.record("Expected .deviceFlowTimedOut")
        } catch IAMIdentityCenterError.deviceFlowTimedOut {
            // expected
        } catch {
            Issue.record("Expected .deviceFlowTimedOut, got \(error)")
        }

    }

    // MARK: - Cancellation

    @Test("cancelSignIn throws .userCancelled and writes no token")
    func cancellation() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let oidcClient = OIDCClient(region: "us-east-1", urlSession: StubURLProtocol.makeSession())
        let sleeper = MockSleeper()
        let service = IdentityCenterService(keychain: keychain, oidcClient: oidcClient, sleeper: sleeper)

        try registerStub()
        try deviceAuthStub(expiresIn: 600, interval: 5)
        try StubURLProtocol.registerOAuthError(urlSubstring: "/token", error: "authorization_pending")

        let signInTask = Task {
            try await service.signIn(
                sessionName: "test-session",
                startUrl: URL(string: "https://example.awsapps.com/start")!,
                region: "us-east-1",
                scopes: ["sso:account:access"],
                verificationHandler: { _ in }
            )
        }

        // Deterministic sync: wait until the polling loop has entered its first sleep.
        await sleeper.waitForNextSleep()
        await service.cancelSignIn(sessionName: "test-session")

        do {
            _ = try await signInTask.value
            Issue.record("Expected .userCancelled")
        } catch IAMIdentityCenterError.userCancelled {
            // expected
        } catch {
            Issue.record("Expected .userCancelled, got \(error)")
        }

        do {
            _ = try await keychain.readRecord(
                StoredSSOToken.self,
                service: IdentityCenterService.ServiceConstants.ssoTokenService,
                account: "test-session"
            )
            Issue.record("Expected no token to be persisted")
        } catch IAMIdentityCenterError.keychainItemMissing {
            // expected
        } catch {
            Issue.record("Expected .keychainItemMissing, got \(error)")
        }

    }

    // MARK: - Cached client reuse

    @Test("Cached OIDC client is reused when fresh")
    func cachedClientReuse() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        try await keychain.writeRecord(
            StoredOIDCClient(
                clientId: "cached-client-id",
                clientSecret: "cached-client-secret",
                issuedAt: Date(),
                secretExpiresAt: Date().addingTimeInterval(90 * 24 * 60 * 60),
                region: "us-east-1",
                scopes: ["sso:account:access"]
            ),
            service: "dev.ajbeck.quorra.oidc-client",
            account: "us-east-1"
        )

        let oidcClient = OIDCClient(region: "us-east-1", urlSession: StubURLProtocol.makeSession())
        let service = IdentityCenterService(keychain: keychain, oidcClient: oidcClient, sleeper: MockSleeper())

        // If RegisterClient is called the test fails — 500 stub causes flow to throw.
        StubURLProtocol.register5xxError(urlSubstring: "/client/register", statusCode: 500)
        try deviceAuthStub()
        try StubURLProtocol.registerSuccess(urlSubstring: "/token", json: [
            "accessToken": "test-access-token",
            "tokenType": "Bearer",
            "expiresIn": 28800,
        ])

        let token = try await service.signIn(
            sessionName: "test-session",
            startUrl: URL(string: "https://example.awsapps.com/start")!,
            region: "us-east-1",
            scopes: ["sso:account:access"],
            verificationHandler: { _ in }
        )
        #expect(token.accessToken == "test-access-token")

    }

    // MARK: - Expired client triggers re-registration

    @Test("OIDC client expiring within 7 days triggers re-registration")
    func expiredClientReregistration() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        try await keychain.writeRecord(
            StoredOIDCClient(
                clientId: "expiring-client-id",
                clientSecret: "expiring-client-secret",
                issuedAt: Date().addingTimeInterval(-83 * 24 * 60 * 60),
                secretExpiresAt: Date().addingTimeInterval(6 * 24 * 60 * 60),
                region: "us-east-1",
                scopes: ["sso:account:access"]
            ),
            service: "dev.ajbeck.quorra.oidc-client",
            account: "us-east-1"
        )

        let oidcClient = OIDCClient(region: "us-east-1", urlSession: StubURLProtocol.makeSession())
        let service = IdentityCenterService(keychain: keychain, oidcClient: oidcClient, sleeper: MockSleeper())

        try registerStub(clientId: "new-client-id", clientSecret: "new-client-secret")
        try deviceAuthStub()
        try StubURLProtocol.registerSuccess(urlSubstring: "/token", json: [
            "accessToken": "test-access-token",
            "tokenType": "Bearer",
            "expiresIn": 28800,
        ])

        let token = try await service.signIn(
            sessionName: "test-session",
            startUrl: URL(string: "https://example.awsapps.com/start")!,
            region: "us-east-1",
            scopes: ["sso:account:access"],
            verificationHandler: { _ in }
        )
        #expect(token.accessToken == "test-access-token")

        let storedClient = try await keychain.readRecord(
            StoredOIDCClient.self,
            service: "dev.ajbeck.quorra.oidc-client",
            account: "us-east-1"
        )
        #expect(storedClient.clientId == "new-client-id")

    }
}
}

// registerStub / deviceAuthStub now live in Stubs/TestHelpers.swift

private func oauthErrorResponse(_ code: String) -> (Data, HTTPURLResponse) {
    let body = "{\"error\":\"\(code)\"}".data(using: .utf8)!
    let response = HTTPURLResponse(
        url: URL(string: "https://oidc.us-east-1.amazonaws.com/token")!,
        statusCode: 400,
        httpVersion: nil,
        headerFields: nil
    )!
    return (body, response)
}

private func tokenSuccessResponse() -> (Data, HTTPURLResponse) {
    let body = "{\"accessToken\":\"test-access-token\",\"tokenType\":\"Bearer\",\"expiresIn\":28800}".data(using: .utf8)!
    let response = HTTPURLResponse(
        url: URL(string: "https://oidc.us-east-1.amazonaws.com/token")!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
    )!
    return (body, response)
}
