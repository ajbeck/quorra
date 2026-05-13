import Foundation
import Testing
@testable import IAMIdentityCenter

actor VerificationCapture {
    var verification: DeviceVerification?

    func record(_ v: DeviceVerification) {
        verification = v
    }
}

@Suite("IdentityCenterService.signIn", .serialized)
struct SignInTests {
    // MARK: - Happy path

    @Test("Happy path: RegisterClient → StartDeviceAuthorization → 2× authorization_pending → success")
    func happyPath() async throws {
        let keychain = Keychain(accessGroup: "test.\(UUID().uuidString)")

        // Clean up any leftover items from previous test runs
        try? await keychain.deleteRecord(service: "dev.ajbeck.quorra.oidc-client", account: "us-east-1")
        try? await keychain.deleteRecord(service: "dev.ajbeck.quorra.sso-token", account: "test-session")

        let urlSession = StubURLProtocol.makeSession()
        let oidcClient = OIDCClient(region: "us-east-1", urlSession: urlSession)
        let sleeper = MockSleeper()
        let service = IdentityCenterService(keychain: keychain, oidcClient: oidcClient, sleeper: sleeper)

        // Stub RegisterClient
        try StubURLProtocol.registerSuccess(urlSubstring: "/client/register", json: [
            "clientId": "test-client-id",
            "clientSecret": "test-client-secret",
            "clientIdIssuedAt": Int(Date().timeIntervalSince1970),
            "clientSecretExpiresAt": Int(Date().addingTimeInterval(90 * 24 * 60 * 60).timeIntervalSince1970),
        ])

        // Stub StartDeviceAuthorization
        try StubURLProtocol.registerSuccess(urlSubstring: "/device_authorization", json: [
            "deviceCode": "test-device-code",
            "userCode": "ABCD-1234",
            "verificationUri": "https://device.sso.us-east-1.amazonaws.com/",
            "verificationUriComplete": "https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-1234",
            "expiresIn": 600,
            "interval": 1,
        ])

        // Stub CreateToken: immediate success (simplest happy path)
        try StubURLProtocol.registerSuccess(urlSubstring: "/token", json: [
            "accessToken": "test-access-token",
            "tokenType": "Bearer",
            "expiresIn": 28800,
            "refreshToken": "test-refresh-token",
        ])

        let captureActor = VerificationCapture()

        async let tokenResult = service.signIn(
            sessionName: "test-session",
            startUrl: URL(string: "https://example.awsapps.com/start")!,
            region: "us-east-1",
            scopes: ["sso:account:access"],
            verificationHandler: { verification in
                await captureActor.record(verification)
            }
        )

        // Wait for the polling loop to start
        while await sleeper.pendingSleeperCount == 0 {
            await Task.yield()
        }
        await sleeper.advance(by: 1.0)

        let token = try await tokenResult

        // Verify token returned
        #expect(token.accessToken == "test-access-token")
        #expect(token.refreshToken == "test-refresh-token")
        #expect(token.sessionName == "test-session")
        #expect(token.region == "us-east-1")

        // Verify verificationHandler was called
        let capturedVerification = await captureActor.verification
        #expect(capturedVerification?.userCode == "ABCD-1234")

        // Verify token landed in Keychain
        let stored = try await keychain.readRecord(
            StoredSSOToken.self,
            service: "dev.ajbeck.quorra.sso-token",
            account: "test-session"
        )
        #expect(stored.accessToken == "test-access-token")

        // Verify OIDC client landed in Keychain
        let storedClient = try await keychain.readRecord(
            StoredOIDCClient.self,
            service: "dev.ajbeck.quorra.oidc-client",
            account: "us-east-1"
        )
        #expect(storedClient.clientId == "test-client-id")

        StubURLProtocol.reset()
    }

    // MARK: - Slow down

    @Test("slow_down increases interval by 5s")
    func slowDown() async throws {
        let keychain = Keychain(accessGroup: "test.\(UUID().uuidString)")
        let urlSession = StubURLProtocol.makeSession()
        let oidcClient = OIDCClient(region: "us-east-1", urlSession: urlSession)
        let sleeper = MockSleeper()
        let service = IdentityCenterService(keychain: keychain, oidcClient: oidcClient, sleeper: sleeper)

        // Stub RegisterClient
        try StubURLProtocol.registerSuccess(urlSubstring: "/client/register", json: [
            "clientId": "test-client-id",
            "clientSecret": "test-client-secret",
            "clientIdIssuedAt": Int(Date().timeIntervalSince1970),
            "clientSecretExpiresAt": Int(Date().addingTimeInterval(90 * 24 * 60 * 60).timeIntervalSince1970),
        ])

        // Stub StartDeviceAuthorization
        try StubURLProtocol.registerSuccess(urlSubstring: "/device_authorization", json: [
            "deviceCode": "test-device-code",
            "userCode": "ABCD-1234",
            "verificationUri": "https://device.sso.us-east-1.amazonaws.com/",
            "verificationUriComplete": "https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-1234",
            "expiresIn": 600,
            "interval": 5,
        ])

        // Set up a sequence of stubs: first /token returns slow_down, second returns success
        // We'll use StubURLProtocol's per-request behavior
        var tokenCallCount = 0
        StubURLProtocol.registerCustom(urlSubstring: "/token") { _ in
            tokenCallCount += 1
            if tokenCallCount == 1 {
                // First call: slow_down
                let json = """
                {"error":"slow_down"}
                """
                let data = json.data(using: .utf8)!
                let response = HTTPURLResponse(url: URL(string: "https://oidc.us-east-1.amazonaws.com/token")!, statusCode: 400, httpVersion: nil, headerFields: nil)!
                return (data, response)
            } else {
                // Second call: success
                let json = """
                {"accessToken":"test-access-token","tokenType":"Bearer","expiresIn":28800}
                """
                let data = json.data(using: .utf8)!
                let response = HTTPURLResponse(url: URL(string: "https://oidc.us-east-1.amazonaws.com/token")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, response)
            }
        }

        async let tokenResult = service.signIn(
            sessionName: "test-session",
            startUrl: URL(string: "https://example.awsapps.com/start")!,
            region: "us-east-1",
            scopes: ["sso:account:access"],
            verificationHandler: { _ in }
        )

        // Wait for first sleep (5s)
        while await sleeper.pendingSleeperCount == 0 {
            await Task.yield()
        }
        await sleeper.advance(by: 5.0)

        // Wait for second sleep (should be 10s after slow_down)
        while await sleeper.pendingSleeperCount == 0 {
            await Task.yield()
        }
        await sleeper.advance(by: 10.0)

        let token = try await tokenResult

        #expect(token.accessToken == "test-access-token")

        // Verify the interval increase: first sleep was 5s, second was 10s (5s + 5s slow_down)
        let recordedSleeps = await sleeper.recordedSleeps
        #expect(recordedSleeps == [5.0, 10.0])

        StubURLProtocol.reset()
    }

    // MARK: - Timeout

    @Test("Wall-clock timeout throws .deviceFlowTimedOut")
    func wallClockTimeout() async throws {
        let keychain = Keychain(accessGroup: "test.\(UUID().uuidString)")
        let urlSession = StubURLProtocol.makeSession()
        let oidcClient = OIDCClient(region: "us-east-1", urlSession: urlSession)
        let sleeper = MockSleeper()
        let service = IdentityCenterService(keychain: keychain, oidcClient: oidcClient, sleeper: sleeper)

        // Stub RegisterClient
        try StubURLProtocol.registerSuccess(urlSubstring: "/client/register", json: [
            "clientId": "test-client-id",
            "clientSecret": "test-client-secret",
            "clientIdIssuedAt": Int(Date().timeIntervalSince1970),
            "clientSecretExpiresAt": Int(Date().addingTimeInterval(90 * 24 * 60 * 60).timeIntervalSince1970),
        ])

        // Stub StartDeviceAuthorization with short expiry
        try StubURLProtocol.registerSuccess(urlSubstring: "/device_authorization", json: [
            "deviceCode": "test-device-code",
            "userCode": "ABCD-1234",
            "verificationUri": "https://device.sso.us-east-1.amazonaws.com/",
            "verificationUriComplete": "https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-1234",
            "expiresIn": 10,
            "interval": 5,
        ])

        // Stub CreateToken: authorization_pending indefinitely
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

        // Wait for first sleep, then advance past expiry (10s + 1s)
        while await sleeper.pendingSleeperCount == 0 {
            await Task.yield()
        }
        await sleeper.advance(by: 11.0)

        do {
            _ = try await signInTask.value
            Issue.record("Expected .deviceFlowTimedOut, but signIn succeeded")
        } catch IAMIdentityCenterError.deviceFlowTimedOut {
            // Expected
        } catch {
            Issue.record("Expected .deviceFlowTimedOut, got \(error)")
        }

        StubURLProtocol.reset()
    }

    // MARK: - Cancellation

    @Test("cancelSignIn throws .userCancelled")
    func cancellation() async throws {
        let keychain = Keychain(accessGroup: "test.\(UUID().uuidString)")

        // Clean up any leftover items
        try? await keychain.deleteRecord(service: "dev.ajbeck.quorra.oidc-client", account: "us-east-1")
        try? await keychain.deleteRecord(service: "dev.ajbeck.quorra.sso-token", account: "test-session")

        let urlSession = StubURLProtocol.makeSession()
        let oidcClient = OIDCClient(region: "us-east-1", urlSession: urlSession)
        let sleeper = MockSleeper()
        let service = IdentityCenterService(keychain: keychain, oidcClient: oidcClient, sleeper: sleeper)

        // Stub RegisterClient
        try StubURLProtocol.registerSuccess(urlSubstring: "/client/register", json: [
            "clientId": "test-client-id",
            "clientSecret": "test-client-secret",
            "clientIdIssuedAt": Int(Date().timeIntervalSince1970),
            "clientSecretExpiresAt": Int(Date().addingTimeInterval(90 * 24 * 60 * 60).timeIntervalSince1970),
        ])

        // Stub StartDeviceAuthorization
        try StubURLProtocol.registerSuccess(urlSubstring: "/device_authorization", json: [
            "deviceCode": "test-device-code",
            "userCode": "ABCD-1234",
            "verificationUri": "https://device.sso.us-east-1.amazonaws.com/",
            "verificationUriComplete": "https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-1234",
            "expiresIn": 600,
            "interval": 5,
        ])

        // Stub CreateToken: authorization_pending indefinitely
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

        // Wait for polling to start
        while await sleeper.pendingSleeperCount == 0 {
            await Task.yield()
        }

        // Cancel mid-poll
        await service.cancelSignIn(sessionName: "test-session")

        do {
            _ = try await signInTask.value
            Issue.record("Expected .userCancelled, but signIn succeeded")
        } catch IAMIdentityCenterError.userCancelled {
            // Expected
        } catch {
            Issue.record("Expected .userCancelled, got \(error)")
        }

        // Verify no token was written
        do {
            _ = try await keychain.readRecord(
                StoredSSOToken.self,
                service: "dev.ajbeck.quorra.sso-token",
                account: "test-session"
            )
            Issue.record("Expected keychainItemMissing, but token was written")
        } catch IAMIdentityCenterError.keychainItemMissing {
            // Expected
        }

        StubURLProtocol.reset()
    }

    // MARK: - Cached client reuse

    @Test("Cached client reuse: does not call RegisterClient when client is fresh")
    func cachedClientReuse() async throws {
        let keychain = Keychain(accessGroup: "test.\(UUID().uuidString)")

        // Pre-populate Keychain with a fresh client
        let freshClient = StoredOIDCClient(
            clientId: "cached-client-id",
            clientSecret: "cached-client-secret",
            issuedAt: Date(),
            secretExpiresAt: Date().addingTimeInterval(90 * 24 * 60 * 60),
            region: "us-east-1",
            scopes: ["sso:account:access"]
        )
        try await keychain.writeRecord(
            freshClient,
            service: "dev.ajbeck.quorra.oidc-client",
            account: "us-east-1"
        )

        let urlSession = StubURLProtocol.makeSession()
        let oidcClient = OIDCClient(region: "us-east-1", urlSession: urlSession)
        let service = IdentityCenterService(keychain: keychain, oidcClient: oidcClient)

        // Stub RegisterClient to FAIL — if it's called, the test fails
        StubURLProtocol.register5xxError(urlSubstring: "/client/register", statusCode: 500)

        // Stub StartDeviceAuthorization
        try StubURLProtocol.registerSuccess(urlSubstring: "/device_authorization", json: [
            "deviceCode": "test-device-code",
            "userCode": "ABCD-1234",
            "verificationUri": "https://device.sso.us-east-1.amazonaws.com/",
            "verificationUriComplete": "https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-1234",
            "expiresIn": 600,
            "interval": 5,
        ])

        // Stub CreateToken: success immediately
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
        StubURLProtocol.reset()
    }

    // MARK: - Expired client triggers re-registration

    @Test("Expired client triggers re-registration")
    func expiredClientReregistration() async throws {
        let keychain = Keychain(accessGroup: "test.\(UUID().uuidString)")

        // Pre-populate Keychain with an expiring client (< 7 days remaining)
        let expiringClient = StoredOIDCClient(
            clientId: "expiring-client-id",
            clientSecret: "expiring-client-secret",
            issuedAt: Date().addingTimeInterval(-83 * 24 * 60 * 60),
            secretExpiresAt: Date().addingTimeInterval(6 * 24 * 60 * 60),
            region: "us-east-1",
            scopes: ["sso:account:access"]
        )
        try await keychain.writeRecord(
            expiringClient,
            service: "dev.ajbeck.quorra.oidc-client",
            account: "us-east-1"
        )

        let urlSession = StubURLProtocol.makeSession()
        let oidcClient = OIDCClient(region: "us-east-1", urlSession: urlSession)
        let service = IdentityCenterService(keychain: keychain, oidcClient: oidcClient)

        // Stub RegisterClient with fresh response
        try StubURLProtocol.registerSuccess(urlSubstring: "/client/register", json: [
            "clientId": "new-client-id",
            "clientSecret": "new-client-secret",
            "clientIdIssuedAt": Int(Date().timeIntervalSince1970),
            "clientSecretExpiresAt": Int(Date().addingTimeInterval(90 * 24 * 60 * 60).timeIntervalSince1970),
        ])

        // Stub StartDeviceAuthorization
        try StubURLProtocol.registerSuccess(urlSubstring: "/device_authorization", json: [
            "deviceCode": "test-device-code",
            "userCode": "ABCD-1234",
            "verificationUri": "https://device.sso.us-east-1.amazonaws.com/",
            "verificationUriComplete": "https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-1234",
            "expiresIn": 600,
            "interval": 5,
        ])

        // Stub CreateToken: success immediately
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

        // Verify new client landed in Keychain
        let storedClient = try await keychain.readRecord(
            StoredOIDCClient.self,
            service: "dev.ajbeck.quorra.oidc-client",
            account: "us-east-1"
        )
        #expect(storedClient.clientId == "new-client-id")

        StubURLProtocol.reset()
    }
}
