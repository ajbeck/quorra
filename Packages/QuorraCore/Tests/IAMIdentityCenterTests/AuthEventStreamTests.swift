import Testing
import Foundation
@testable import IAMIdentityCenter

extension IAMIdentityCenterTestSuite {
@Suite("AuthEvent stream", .serialized, .timeLimit(.minutes(1)))
struct AuthEventStreamTests {

    // MARK: - signIn emits correct events

    @Test("Successful signIn emits signInStarted then signedIn")
    func signInEmitsEvents() async throws {
        let keychain = InMemoryKeychainStore()
        let stub = StubOIDCRequesting()
        await stub.setNextRegisterResult(.success(makeStoredClient()))
        await stub.setNextStartDeviceAuthorizationResult(.success(("test-device-code", makeVerification(interval: 1))))
        await stub.setNextCreateTokenResult(.success(makeDefaultSSOToken(accessToken: "test-access-token", refreshToken: nil, sessionName: "test-session")))
        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(stub))

        let collector = EventCollector()
        let collectTask = Task {
            for await event in service.events {
                await collector.append(event)
                if case .signedIn = event { break }
            }
        }

        _ = try await service.signIn(
            sessionName: "test-session",
            startUrl: URL(string: "https://example.awsapps.com/start")!,
            region: "us-east-1",
            scopes: ["sso:account:access"],
            verificationHandler: { _ in }
        )

        await collectTask.value

        let receivedEvents = await collector.events
        #expect(receivedEvents.contains(.signInStarted(sessionName: "test-session")))
        #expect(receivedEvents.contains(.signedIn(sessionName: "test-session")))
        #expect(!receivedEvents.contains(.signInFailed(sessionName: "test-session")))
        #expect(!receivedEvents.contains(.signInCancelled(sessionName: "test-session")))

        // Verify order: signInStarted before signedIn
        if let startedIdx = receivedEvents.firstIndex(of: .signInStarted(sessionName: "test-session")),
           let signedInIdx = receivedEvents.firstIndex(of: .signedIn(sessionName: "test-session")) {
            #expect(startedIdx < signedInIdx)
        } else {
            Issue.record("Missing signInStarted or signedIn in event stream")
        }
    }

    // MARK: - Failed signIn emits signInFailed

    @Test("Failed signIn emits signInStarted then signInFailed")
    func failedSignInEmitsEvents() async throws {
        let keychain = InMemoryKeychainStore()
        let stub = StubOIDCRequesting()
        await stub.setNextRegisterResult(.success(makeStoredClient()))
        await stub.setNextStartDeviceAuthorizationResult(.success(("test-device-code", makeVerification(interval: 1, expiresIn: 10))))
        // Always report the browser step as incomplete → wall clock expires first.
        await stub.setNextCreateTokenResult(.failure(IAMIdentityCenterError.authorizationPending))
        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(stub))

        let collector = EventCollector()
        let collectTask = Task {
            for await event in service.events {
                await collector.append(event)
                if case .signInFailed = event { break }
            }
        }

        do {
            _ = try await service.signIn(
                sessionName: "test-session",
                startUrl: URL(string: "https://example.awsapps.com/start")!,
                region: "us-east-1",
                scopes: ["sso:account:access"],
                verificationHandler: { _ in }
            )
        } catch IAMIdentityCenterError.deviceFlowTimedOut {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        await collectTask.value

        let receivedEvents = await collector.events
        #expect(receivedEvents.contains(.signInStarted(sessionName: "test-session")))
        #expect(receivedEvents.contains(.signInFailed(sessionName: "test-session")))
        #expect(!receivedEvents.contains(.signedIn(sessionName: "test-session")))
    }

    // MARK: - Cancelled signIn emits signInCancelled

    @Test("Cancelled signIn emits signInStarted then signInCancelled")
    func cancelledSignInEmitsEvents() async throws {
        let keychain = InMemoryKeychainStore()
        let stub = StubOIDCRequesting()
        await stub.setNextRegisterResult(.success(makeStoredClient()))
        await stub.setNextStartDeviceAuthorizationResult(.success(("test-device-code", makeVerification(interval: 5))))
        // Poll never succeeds; the test cancels mid-poll and expects .signInCancelled.
        await stub.setNextCreateTokenResult(.failure(IAMIdentityCenterError.authorizationPending))
        let sleeper = MockSleeper()
        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(stub), sleeper: sleeper)

        let collector = EventCollector()
        let collectTask = Task {
            for await event in service.events {
                await collector.append(event)
                if case .signInCancelled = event { break }
            }
        }

        let signInTask = Task {
            try await service.signIn(
                sessionName: "test-session",
                startUrl: URL(string: "https://example.awsapps.com/start")!,
                region: "us-east-1",
                scopes: ["sso:account:access"],
                verificationHandler: { _ in }
            )
        }

        await sleeper.waitForNextSleep()
        await service.cancelSignIn(sessionName: "test-session")

        do {
            _ = try await signInTask.value
        } catch IAMIdentityCenterError.userCancelled {
            // expected
        }

        await collectTask.value

        let receivedEvents = await collector.events
        #expect(receivedEvents.contains(.signInStarted(sessionName: "test-session")))
        #expect(receivedEvents.contains(.signInCancelled(sessionName: "test-session")))
        #expect(!receivedEvents.contains(.signedIn(sessionName: "test-session")))
    }

    // MARK: - signOut emits signedOut

    @Test("signOut emits signedOut event")
    func signOutEmitsEvent() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let stubSession = StubURLProtocol.makeSession()
        try await keychain.writeRecord(
            StoredSSOToken(
                accessToken: "tok",
                expiresAt: Date().addingTimeInterval(3600),
                refreshToken: nil,
                issuedAt: Date(),
                region: "us-east-1",
                sessionName: "test-session"
            ),
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: "test-session"
        )

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

        let service = IdentityCenterService(
            keychain: keychain,
            oidcClientProvider: makeStubOIDCProvider(StubOIDCRequesting()),
            urlSession: stubSession
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

        let receivedEvents = await collector.events
        #expect(receivedEvents.contains(.signedOut(sessionName: "test-session")))
    }

    // MARK: - signOut server failure emits signOutServerSideFailed

    @Test("signOut with /logout failure emits signedOut then signOutServerSideFailed")
    func signOutServerFailure() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let stubSession = StubURLProtocol.makeSession()
        try await keychain.writeRecord(
            StoredSSOToken(
                accessToken: "tok",
                expiresAt: Date().addingTimeInterval(3600),
                refreshToken: nil,
                issuedAt: Date(),
                region: "us-east-1",
                sessionName: "test-session"
            ),
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: "test-session"
        )

        StubURLProtocol.registerNetworkFailure(urlSubstring: "/logout")

        let service = IdentityCenterService(
            keychain: keychain,
            oidcClientProvider: makeStubOIDCProvider(StubOIDCRequesting()),
            urlSession: stubSession
        )

        let collector = EventCollector()
        let collectTask = Task {
            for await event in service.events {
                await collector.append(event)
                if case .signOutServerSideFailed = event { break }
            }
        }

        try await service.signOut(sessionName: "test-session")
        await collectTask.value

        let receivedEvents = await collector.events
        #expect(receivedEvents.contains(.signedOut(sessionName: "test-session")))
        #expect(receivedEvents.contains(.signOutServerSideFailed(sessionName: "test-session")))

        // Verify order: signedOut before signOutServerSideFailed
        if let outIdx = receivedEvents.firstIndex(of: .signedOut(sessionName: "test-session")),
           let failIdx = receivedEvents.firstIndex(of: .signOutServerSideFailed(sessionName: "test-session")) {
            #expect(outIdx < failIdx)
        }
    }

    // MARK: - Expiration event

    @Test("Expiration timer emits .expired event")
    func expirationEmitsEvent() async throws {
        let keychain = InMemoryKeychainStore()
        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(StubOIDCRequesting()))

        let collector = EventCollector()
        let collectTask = Task {
            for await event in service.events {
                await collector.append(event)
                if case .expired = event { break }
            }
        }

        // Schedule immediate expiration
        await service.scheduleExpiration(forSession: "test-session", expiresAt: Date().addingTimeInterval(0.05))

        try await Task.sleep(for: .milliseconds(300))
        collectTask.cancel()
        await collectTask.value

        let receivedEvents = await collector.events
        #expect(receivedEvents.contains(.expired(sessionName: "test-session")))
    }
}
}

// EventCollector / registerStub / deviceAuthStub now live in Stubs/TestHelpers.swift
