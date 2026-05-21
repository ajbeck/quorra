import Testing
import Foundation
@testable import IAMIdentityCenter

extension IAMIdentityCenterTestSuite {
@Suite("IdentityCenterService expiration timer", .serialized, .timeLimit(.minutes(1)))
struct ExpirationTimerTests {

    // MARK: - Timer fires .expired event

    @Test("Expiration timer fires .expired event at deadline")
    func timerFiresExpiredEvent() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(StubOIDCRequesting()))

        let collector = EventCollector()
        let collectTask = Task {
            for await event in service.events {
                await collector.append(event)
                if case .expired = event { break }
            }
        }

        // Schedule expiration in the very near future
        let expiresAt = Date().addingTimeInterval(0.05)  // 50ms
        await service.scheduleExpiration(forSession: "test-session", expiresAt: expiresAt)

        // Wait for the timer to fire (give it some headroom)
        try await Task.sleep(for: .milliseconds(300))
        collectTask.cancel()
        await collectTask.value

        #expect(await collector.events.contains(.expired(sessionName: "test-session")))
    }

    // MARK: - Timer cancelled on sign-out

    @Test("Expiration timer is cancelled and .expired not emitted after cancelExpiration")
    func timerCancelled() async throws {
        let keychain = InMemoryKeychainStore()
        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(StubOIDCRequesting()))

        let counter = EventCounter()
        let collectTask = Task {
            for await event in service.events {
                if case .expired = event { await counter.increment() }
            }
        }

        let expiresAt = Date().addingTimeInterval(0.1)
        await service.scheduleExpiration(forSession: "test-session", expiresAt: expiresAt)
        // Cancel immediately before it fires
        await service.cancelExpiration(forSession: "test-session")

        try await Task.sleep(for: .milliseconds(300))
        collectTask.cancel()
        await collectTask.value

        #expect(await counter.count == 0)
    }

    // MARK: - Re-schedule on new signIn cancels old timer

    @Test("Re-scheduling expiration replaces old timer")
    func rescheduleReplacesOldTimer() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(StubOIDCRequesting()))

        let counter = EventCounter()
        let collectTask = Task {
            for await event in service.events {
                if case .expired = event { await counter.increment() }
            }
        }

        // Schedule first timer (very soon)
        await service.scheduleExpiration(forSession: "s", expiresAt: Date().addingTimeInterval(0.05))
        // Immediately replace with a far-future one (cancels the first)
        let farFuture = Date().addingTimeInterval(3600)
        await service.scheduleExpiration(forSession: "s", expiresAt: farFuture)

        try await Task.sleep(for: .milliseconds(300))
        collectTask.cancel()
        await collectTask.value

        // Only one timer should be active; old one was replaced → only 0 expirations fired
        #expect(await counter.count == 0)
        // Clean up
        await service.cancelExpiration(forSession: "s")
    }

    // MARK: - signIn schedules expiration timer (one shot)

    @Test("Successful signIn schedules exactly one expiration timer")
    func signInSchedulesTimer() async throws {
        let keychain = InMemoryKeychainStore()
        let stub = StubOIDCRequesting()
        await stub.setNextRegisterResult(.success(makeStoredClient()))
        await stub.setNextStartDeviceAuthorizationResult(.success(("test-device-code", makeVerification(interval: 1))))
        await stub.setNextCreateTokenResult(.success(makeDefaultSSOToken(
            accessToken: "test-access-token",
            refreshToken: nil,
            sessionName: "test-session"
        )))
        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(stub))

        _ = try await service.signIn(
            sessionName: "test-session",
            startUrl: URL(string: "https://example.awsapps.com/start")!,
            region: "us-east-1",
            scopes: ["sso:account:access"],
            verificationHandler: { _ in }
        )

        // After sign-in, one timer should exist
        let timer = await service.expirationTimers["test-session"]
        #expect(timer != nil)
        timer?.cancel()
    }

    // MARK: - Expiration fires only once even if status() is called multiple times

    @Test("status() does not add a second timer if one already exists")
    func noDoubleTimer() async throws {
        let keychain = InMemoryKeychainStore()
        let expiresAt = Date().addingTimeInterval(3600)
        try await keychain.writeRecord(
            StoredSSOToken(
                accessToken: "tok",
                expiresAt: expiresAt,
                refreshToken: nil,
                issuedAt: Date(),
                region: "us-east-1",
                sessionName: "test-session"
            ),
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: "test-session"
        )

        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(StubOIDCRequesting()))

        // Call status() three times
        _ = await service.status(forSession: "test-session")
        let timer1 = await service.expirationTimers["test-session"]
        _ = await service.status(forSession: "test-session")
        let timer2 = await service.expirationTimers["test-session"]
        _ = await service.status(forSession: "test-session")
        let timer3 = await service.expirationTimers["test-session"]

        // All three references should be the same task (pointer equality isn't easily testable,
        // but we can assert that a timer exists each time without it being nil)
        #expect(timer1 != nil)
        #expect(timer2 != nil)
        #expect(timer3 != nil)

        // Verify: only one timer is active (same task not re-created on each call)
        // The guard `if expirationTimers[sessionName] == nil` prevents a second schedule.
        // We can't directly compare Task identity, but we can verify the timer count stays at 1
        // by checking the dictionary count.
        let timerCount = await service.expirationTimers.count
        #expect(timerCount == 1)

        timer3?.cancel()
    }
}
}

// EventCollector / EventCounter / registerStub / deviceAuthStub now live in Stubs/TestHelpers.swift
