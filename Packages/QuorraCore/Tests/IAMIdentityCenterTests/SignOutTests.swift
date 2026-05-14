import Testing
import Foundation
@testable import IAMIdentityCenter

extension IAMIdentityCenterTestSuite {
@Suite("IdentityCenterService.signOut", .serialized, .timeLimit(.minutes(1)))
struct SignOutTests {

    // MARK: - Happy path

    @Test("Happy path: Keychain row deleted, /logout fired, signedOut event emitted")
    func happyPath() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let token = makeToken()
        try await keychain.writeRecord(
            token,
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: "test-session"
        )

        let stubSession = StubURLProtocol.makeSession()
        let oidcClient = OIDCClient(region: "us-east-1", urlSession: stubSession)
        let service = IdentityCenterService(
            keychain: keychain,
            oidcClient: oidcClient,
            urlSession: stubSession
        )

        // Stub /logout success (204 No Content is typical; we use 200 for simplicity)
        StubURLProtocol.register(
            urlSubstring: "/logout",
            response: .success(
                Data(),
                HTTPURLResponse(
                    url: URL(string: "https://portal.sso.us-east-1.amazonaws.com/logout")!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!
            )
        )

        let collector = EventCollector()
        let collectTask = Task {
            for await event in service.events {
                await collector.append(event)
                if case .signedOut = event { break }
            }
        }

        try await service.signOut(sessionName: "test-session")
        await collectTask.value

        // Keychain row should be gone
        do {
            _ = try await keychain.readRecord(
                StoredSSOToken.self,
                service: IdentityCenterService.ServiceConstants.ssoTokenService,
                account: "test-session"
            )
            Issue.record("Expected token to be deleted from Keychain")
        } catch IAMIdentityCenterError.keychainItemMissing {
            // expected
        }

        let receivedEvents = await collector.events
        #expect(receivedEvents.contains(.signedOut(sessionName: "test-session")))
        #expect(!receivedEvents.contains(.signOutServerSideFailed(sessionName: "test-session")))
    }

    // MARK: - Server failure: still signed out locally, advisory event emitted

    @Test("Server /logout failure: signedOut + signOutServerSideFailed both emitted, Keychain cleared")
    func serverFailure() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let token = makeToken()
        try await keychain.writeRecord(
            token,
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: "test-session"
        )

        let stubSession = StubURLProtocol.makeSession()
        let oidcClient = OIDCClient(region: "us-east-1", urlSession: stubSession)
        let service = IdentityCenterService(
            keychain: keychain,
            oidcClient: oidcClient,
            urlSession: stubSession
        )

        // Stub /logout failure
        StubURLProtocol.registerNetworkFailure(urlSubstring: "/logout")

        let collector = EventCollector()
        let collectTask = Task {
            for await event in service.events {
                await collector.append(event)
                if case .signOutServerSideFailed = event { break }
            }
        }

        try await service.signOut(sessionName: "test-session")
        await collectTask.value

        // Keychain should still be cleared
        do {
            _ = try await keychain.readRecord(
                StoredSSOToken.self,
                service: IdentityCenterService.ServiceConstants.ssoTokenService,
                account: "test-session"
            )
            Issue.record("Expected token to be deleted even on /logout failure")
        } catch IAMIdentityCenterError.keychainItemMissing {
            // expected
        }

        let receivedEvents = await collector.events
        #expect(receivedEvents.contains(.signedOut(sessionName: "test-session")))
        #expect(receivedEvents.contains(.signOutServerSideFailed(sessionName: "test-session")))
    }

    // MARK: - Idempotent: missing row

    @Test("signOut is idempotent when no token exists")
    func missingRow() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let stubSession = StubURLProtocol.makeSession()
        let oidcClient = OIDCClient(region: "us-east-1", urlSession: stubSession)
        let service = IdentityCenterService(
            keychain: keychain,
            oidcClient: oidcClient,
            urlSession: stubSession
        )

        let collector = EventCollector()
        let collectTask = Task {
            for await event in service.events {
                await collector.append(event)
                if case .signedOut = event { break }
            }
        }

        // Should NOT throw, even without a token
        try await service.signOut(sessionName: "no-such-session")
        await collectTask.value

        let receivedEvents = await collector.events
        #expect(receivedEvents.contains(.signedOut(sessionName: "no-such-session")))
        // No /logout should have been fired (no token → early return)
        #expect(!receivedEvents.contains(.signOutServerSideFailed(sessionName: "no-such-session")))
    }

    // MARK: - In-flight signIn is cancelled before sign-out

    @Test("In-flight signIn is cancelled before sign-out proceeds")
    func cancelsInFlightSignIn() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let oidcClient = OIDCClient(region: "us-east-1", urlSession: StubURLProtocol.makeSession())
        let sleeper = MockSleeper()
        let stubSession = StubURLProtocol.makeSession()
        let service = IdentityCenterService(
            keychain: keychain,
            oidcClient: oidcClient,
            sleeper: sleeper,
            urlSession: stubSession
        )

        try registerStub()
        try deviceAuthStub(expiresIn: 600, interval: 5)
        try StubURLProtocol.registerOAuthError(urlSubstring: "/token", error: "authorization_pending")
        // No /logout stub needed — no token in keychain so signOut exits early after cancelling sign-in

        // Start sign-in in the background
        let signInTask = Task {
            try await service.signIn(
                sessionName: "test-session",
                startUrl: URL(string: "https://example.awsapps.com/start")!,
                region: "us-east-1",
                scopes: ["sso:account:access"],
                verificationHandler: { _ in }
            )
        }

        // Wait until polling loop enters first sleep
        await sleeper.waitForNextSleep()

        // Now sign out — should cancel the in-flight sign-in
        // No token in Keychain yet so signOut returns after emitting signedOut
        try await service.signOut(sessionName: "test-session")

        // The signIn task should have been cancelled and thrown userCancelled
        do {
            _ = try await signInTask.value
            Issue.record("Expected .userCancelled from signIn")
        } catch IAMIdentityCenterError.userCancelled {
            // expected
        } catch {
            Issue.record("Expected .userCancelled, got \(error)")
        }
    }

    // MARK: - Expiration timer cancelled on sign-out

    @Test("Expiration timer is cancelled on successful sign-out")
    func expirationTimerCancelled() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let token = makeToken()
        try await keychain.writeRecord(
            token,
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: "test-session"
        )

        let stubSession = StubURLProtocol.makeSession()
        let oidcClient = OIDCClient(region: "us-east-1", urlSession: stubSession)
        let service = IdentityCenterService(
            keychain: keychain,
            oidcClient: oidcClient,
            urlSession: stubSession
        )

        // Manually seed an expiration timer
        await service.scheduleExpiration(forSession: "test-session", expiresAt: token.expiresAt)
        let timerBefore = await service.expirationTimers["test-session"]
        #expect(timerBefore != nil)

        StubURLProtocol.register(
            urlSubstring: "/logout",
            response: .success(
                Data(),
                HTTPURLResponse(
                    url: URL(string: "https://portal.sso.us-east-1.amazonaws.com/logout")!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!
            )
        )

        try await service.signOut(sessionName: "test-session")

        let timerAfter = await service.expirationTimers["test-session"]
        #expect(timerAfter == nil)
    }
}
}

// EventCollector / registerStub / deviceAuthStub now live in Stubs/TestHelpers.swift

// MARK: - Helpers

private func makeToken(sessionName: String = "test-session") -> StoredSSOToken {
    StoredSSOToken(
        accessToken: "test-access-token",
        expiresAt: Date().addingTimeInterval(8 * 3600),
        refreshToken: nil,
        issuedAt: Date(),
        region: "us-east-1",
        sessionName: sessionName
    )
}

