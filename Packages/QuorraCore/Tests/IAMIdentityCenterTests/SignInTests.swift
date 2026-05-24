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
/// the actor, a protocol-level OIDC stub injected through the provider seam, an in-memory
/// keychain store, and a synthetic sleeper to assert end-to-end flow behavior. Wire encoding
/// is owned by the AWS SDK and is not retested here (test the code you own, not your dependencies).
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
        let keychain = InMemoryKeychainStore()
        let stub = StubOIDCRequesting()
        await stub.setNextRegisterResult(.success(makeStoredClient(clientId: "test-client-id", clientSecret: "test-client-secret")))
        await stub.setNextStartDeviceAuthorizationResult(.success(("test-device-code", makeVerification(userCode: "ABCD-1234", interval: 1))))
        await stub.setNextCreateTokenResult(.success(makeDefaultSSOToken(
            accessToken: "test-access-token",
            refreshToken: "test-refresh-token",
            sessionName: "test-session"
        )))
        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(stub), sleeper: MockSleeper())

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
        let keychain = InMemoryKeychainStore()
        let stub = StubOIDCRequesting()
        await stub.setNextRegisterResult(.success(makeStoredClient()))
        await stub.setNextStartDeviceAuthorizationResult(.success(("test-device-code", makeVerification(interval: 5))))

        // First createToken poll → .slowDown; second → success.
        let tokenCallCount = Mutex<Int>(0)
        await stub.setCreateTokenBlock {
            let n = tokenCallCount.withLock { count -> Int in
                count += 1
                return count
            }
            if n == 1 { throw IAMIdentityCenterError.slowDown }
            return makeDefaultSSOToken(accessToken: "test-access-token", sessionName: "test-session")
        }

        let sleeper = MockSleeper()
        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(stub), sleeper: sleeper)

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
        let keychain = InMemoryKeychainStore()
        let stub = StubOIDCRequesting()
        await stub.setNextRegisterResult(.success(makeStoredClient()))
        await stub.setNextStartDeviceAuthorizationResult(.success(("test-device-code", makeVerification(interval: 5, expiresIn: 10))))
        // createToken never completes the flow — always reports the user hasn't finished yet,
        // so the poll loop runs until the wall-clock deadline (expiresIn: 10) is exceeded.
        await stub.setCreateTokenBlock { throw IAMIdentityCenterError.authorizationPending }
        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(stub), sleeper: MockSleeper())

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
        let keychain = InMemoryKeychainStore()
        let stub = StubOIDCRequesting()
        let sleeper = MockSleeper()
        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(stub), sleeper: sleeper)

        // Gate the createToken call so it blocks until the sign-in Task is cancelled.
        // This eliminates the scheduling race between MockSleeper.sleep(for:)'s Task.yield()
        // and the cancelSignIn actor-hop: whether or not Task.checkCancellation() catches the
        // cancellation before createToken is reached, the for-await below will catch it
        // (AsyncStream.next() returns nil when the enclosing Task is cancelled, causing the
        // loop to exit and the explicit CancellationError to propagate).  Either path through
        // pollForToken results in CancellationError → signIn maps to .userCancelled.
        let (gateStream, _) = AsyncStream<Void>.makeStream()
        await stub.setCreateTokenBlock {
            for await _ in gateStream { break }   // exits when task is cancelled (stream → nil)
            throw CancellationError()
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

        // Deterministic sync point: wait until the polling loop has entered its first sleep.
        // After this, the poll loop is at Task.yield()/checkCancellation() or createToken.
        await sleeper.waitForSleepCount(atLeast: 1)
        // Cancel the sign-in. If checkCancellation() hasn't fired yet, the gated createToken
        // will observe the cancellation and throw CancellationError deterministically.
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

        let stub = StubOIDCRequesting()
        // If RegisterClient is called the test fails — a fresh cached client must be reused.
        await stub.setNextRegisterResult(.failure(IAMIdentityCenterError.invalidClient))
        await stub.setNextStartDeviceAuthorizationResult(.success(("test-device-code", makeVerification())))
        await stub.setNextCreateTokenResult(.success(makeDefaultSSOToken(
            accessToken: "test-access-token",
            refreshToken: nil,
            sessionName: "test-session"
        )))
        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(stub), sleeper: MockSleeper())

        let token = try await service.signIn(
            sessionName: "test-session",
            startUrl: URL(string: "https://example.awsapps.com/start")!,
            region: "us-east-1",
            scopes: ["sso:account:access"],
            verificationHandler: { _ in }
        )
        #expect(token.accessToken == "test-access-token")
        // Cached client was reused — no re-registration occurred.
        #expect(await stub.registerCallCount == 0)

    }

    // MARK: - Expired client triggers re-registration

    @Test("OIDC client expiring within 7 days triggers re-registration")
    func expiredClientReregistration() async throws {
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

        let stub = StubOIDCRequesting()
        await stub.setNextRegisterResult(.success(makeStoredClient(clientId: "new-client-id", clientSecret: "new-client-secret")))
        await stub.setNextStartDeviceAuthorizationResult(.success(("test-device-code", makeVerification())))
        await stub.setNextCreateTokenResult(.success(makeDefaultSSOToken(
            accessToken: "test-access-token",
            refreshToken: nil,
            sessionName: "test-session"
        )))
        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(stub), sleeper: MockSleeper())

        let token = try await service.signIn(
            sessionName: "test-session",
            startUrl: URL(string: "https://example.awsapps.com/start")!,
            region: "us-east-1",
            scopes: ["sso:account:access"],
            verificationHandler: { _ in }
        )
        #expect(token.accessToken == "test-access-token")
        #expect(await stub.registerCallCount == 1)

        let storedClient = try await keychain.readRecord(
            StoredOIDCClient.self,
            service: "dev.ajbeck.quorra.oidc-client",
            account: "us-east-1"
        )
        #expect(storedClient.clientId == "new-client-id")

    }

    @Test("Cached OIDC client with different scopes triggers re-registration")
    func scopeMismatchReregisters() async throws {
        let keychain = InMemoryKeychainStore()
        try await keychain.writeRecord(
            makeStoredClient(
                clientId: "old-scope-client-id",
                region: "us-east-1",
                scopes: ["sso:account:access"]
            ),
            service: "dev.ajbeck.quorra.oidc-client",
            account: "us-east-1"
        )

        let requestedScopes = ["sso:account:access", "codewhisperer:completions"]
        let stub = StubOIDCRequesting()
        await stub.setNextRegisterResult(.success(makeStoredClient(
            clientId: "new-scope-client-id",
            region: "us-east-1",
            scopes: requestedScopes
        )))
        await stub.setNextStartDeviceAuthorizationResult(.success(("test-device-code", makeVerification())))
        await stub.setNextCreateTokenResult(.success(makeDefaultSSOToken(
            accessToken: "test-access-token",
            refreshToken: nil,
            sessionName: "test-session"
        )))
        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(stub), sleeper: MockSleeper())

        _ = try await service.signIn(
            sessionName: "test-session",
            startUrl: URL(string: "https://example.awsapps.com/start")!,
            region: "us-east-1",
            scopes: requestedScopes,
            verificationHandler: { _ in }
        )

        #expect(await stub.registerCallCount == 1)
        let cached = try await keychain.readRecord(
            StoredOIDCClient.self,
            service: "dev.ajbeck.quorra.oidc-client",
            account: "us-east-1"
        )
        #expect(cached.clientId == "new-scope-client-id")
        #expect(Set(cached.scopes) == Set(requestedScopes))
    }

    // MARK: - Invalid cached client triggers re-registration + retry

    @Test("Cached OIDC client rejected as invalid re-registers and retries device authorization")
    func invalidCachedClientReregistersAndRetries() async throws {
        let keychain = InMemoryKeychainStore()
        // Seed a stale cached client that is NOT near time-expiry, so ensureOIDCClient hands it
        // back as-is. It simulates a registration that was revoked / deleted server-side or (the
        // migration case) cached against the wrong region — invalid only when actually used.
        try await keychain.writeRecord(
            makeStoredClient(clientId: "stale-client-id", region: "us-east-2"),
            service: "dev.ajbeck.quorra.oidc-client",
            account: "us-east-2"
        )

        let stub = StubOIDCRequesting()
        await stub.setNextRegisterResult(.success(makeStoredClient(clientId: "fresh-client-id", region: "us-east-2")))
        // First device-auth call rejects the stale client; the second (after re-register) succeeds.
        let attempt = Mutex<Int>(0)
        await stub.setStartDeviceAuthorizationBlock {
            let n = attempt.withLock { count -> Int in count += 1; return count }
            if n == 1 { throw IAMIdentityCenterError.invalidClient }
            return ("test-device-code", makeVerification())
        }
        await stub.setNextCreateTokenResult(.success(makeDefaultSSOToken(
            accessToken: "test-access-token",
            refreshToken: nil,
            sessionName: "test-session"
        )))

        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(stub), sleeper: MockSleeper())

        let token = try await service.signIn(
            sessionName: "test-session",
            startUrl: URL(string: "https://asteroidcomputing.awsapps.com/start")!,
            region: "us-east-2",
            scopes: ["sso:account:access"],
            verificationHandler: { _ in }
        )

        #expect(token.accessToken == "test-access-token")
        // Recovery happened: exactly one re-registration and two device-auth attempts.
        #expect(await stub.registerCallCount == 1)
        #expect(await stub.startDeviceAuthorizationCallCount == 2)

        // The stale cached client was overwritten with the fresh registration.
        let cached = try await keychain.readRecord(
            StoredOIDCClient.self,
            service: "dev.ajbeck.quorra.oidc-client",
            account: "us-east-2"
        )
        #expect(cached.clientId == "fresh-client-id")
    }
}
}
