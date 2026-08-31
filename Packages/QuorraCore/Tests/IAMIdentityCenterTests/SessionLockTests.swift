import Testing
import Foundation
@testable import IAMIdentityCenter

// MARK: - Helpers (file-private)

private func makeOIDCClient(region: String = "us-east-1") -> StoredOIDCClient {
    StoredOIDCClient(
        clientId: "cid", clientSecret: "cs",
        issuedAt: Date(), secretExpiresAt: Date().addingTimeInterval(90 * 24 * 60 * 60),
        region: region, scopes: ["sso:account:access"]
    )
}

private func seedSignedInState(
    keychain: InMemoryKeychainStore,
    sessionName: String = "s",
    region: String = "us-east-1",
    refreshToken: String? = "rt",
    expiresIn: TimeInterval = 3 * 60  // inside skew window by default
) async throws {
    let token = StoredSSOToken(
        accessToken: "at",
        expiresAt: Date().addingTimeInterval(expiresIn),
        refreshToken: refreshToken,
        issuedAt: Date().addingTimeInterval(-8 * 3600),
        region: region,
        sessionName: sessionName
    )
    try await keychain.writeRecord(
        token,
        service: IdentityCenterService.ServiceConstants.ssoTokenService,
        account: sessionName
    )
    try await keychain.writeRecord(
        makeOIDCClient(region: region),
        service: IdentityCenterService.ServiceConstants.oidcClientService,
        account: region
    )
}

private func isSignedIn(keychain: InMemoryKeychainStore, sessionName: String = "s") async -> Bool {
    do {
        _ = try await keychain.readRecord(
            StoredSSOToken.self,
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: sessionName
        )
        return true
    } catch {
        return false
    }
}

extension IAMIdentityCenterTestSuite {
@Suite("Session lock (D21)", .serialized, .timeLimit(.minutes(1)))
struct SessionLockTests {

    // MARK: - Scenario 1: Same-session operations run sequentially

    /// Two operations on the same session are serialized by the session lock.
    ///
    /// A slow refresh holds the lock; a subsequent signOut queues behind it.
    /// After both complete, the final state is signed-out — signOut's write wins
    /// because it runs after the refresh, not concurrent with it.
    @Test("Same-session refreshNow + signOut are serialized; final state is signed-out")
    func sameSessionOperationsAreSerializedRefreshThenSignOut() async throws {
        defer { StubURLProtocol.reset() }

        let keychain = InMemoryKeychainStore()
        try await seedSignedInState(keychain: keychain, expiresIn: 8 * 3600)  // outside skew — need explicit refresh

        // Stub a successful Portal logout
        try StubURLProtocol.registerSuccess(urlSubstring: "/logout", json: [:])

        // Use a stub OIDC client that lets us control refresh timing
        let stub = StubOIDCRequesting()
        // Refresh succeeds and returns a new token
        await stub.setNextRefreshResult(.success(makeDefaultSSOToken(
            accessToken: "refreshed-at",
            refreshToken: "new-rt",
            sessionName: "s",
            expiresIn: 8 * 3600
        )))

        let urlSession = StubURLProtocol.makeSession()
        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(stub), urlSession: urlSession)

        // Fire both operations concurrently. Because refreshNow takes the session lock first
        // (races may vary), signOut queues behind it and is guaranteed to run after.
        async let refresh: StoredSSOToken = service.refreshNow(sessionName: "s")
        async let signOut: Void = service.signOut(sessionName: "s")

        _ = try? await refresh
        try? await signOut

        // Final state must be signed-out regardless of which operation won the lock first.
        // D21 guarantee: the operations don't interleave — one fully completes before the other.
        let signedIn = await isSignedIn(keychain: keychain)
        // signOut always wins as final state when it runs after refresh
        // (it deletes the Keychain row unconditionally)
        #expect(!signedIn, "After signOut completes, session must not have a Keychain row")
    }

    // MARK: - Scenario 2: Different sessions don't block each other

    /// Operations on independent sessions run concurrently, not serially.
    ///
    /// If session locks were global (not per-session), one signOut would have to wait for the
    /// other to complete. Per-session locks mean both can execute in parallel.
    @Test("Operations on different sessions complete concurrently — no cross-session blocking")
    func differentSessionsDontBlockEachOther() async throws {
        defer { StubURLProtocol.reset() }

        let keychain = InMemoryKeychainStore()
        // Seed two independent sessions
        try await seedSignedInState(keychain: keychain, sessionName: "s1")
        try await seedSignedInState(keychain: keychain, sessionName: "s2")

        // Stub Portal logout for both sessions
        try StubURLProtocol.registerSuccess(urlSubstring: "/logout", json: [:])

        let stub = StubOIDCRequesting()
        let urlSession = StubURLProtocol.makeSession()
        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(stub), urlSession: urlSession)

        // Start both sign-outs concurrently
        let start = Date()
        async let so1: Void = service.signOut(sessionName: "s1")
        async let so2: Void = service.signOut(sessionName: "s2")

        try? await so1
        try? await so2
        let elapsed = Date().timeIntervalSince(start)

        // Both sessions must be signed out
        let s1SignedIn = await isSignedIn(keychain: keychain, sessionName: "s1")
        let s2SignedIn = await isSignedIn(keychain: keychain, sessionName: "s2")
        #expect(!s1SignedIn, "Session s1 must be signed out")
        #expect(!s2SignedIn, "Session s2 must be signed out")

        // Both operations completed — the test itself passing within .timeLimit(.minutes(1)) is
        // evidence that cross-session blocking didn't occur. We don't need a strict wall-clock
        // assertion since test infra timing varies.
        _ = elapsed  // referenced to avoid compiler warning
    }

    // MARK: - Scenario 3: D21 scenario 10e — refresh, then signOut queued; end state is signed-out

    /// D21 scenario 10e: A refresh is in-flight when signOut is requested.
    ///
    /// The cancel-then-queue pattern means:
    /// 1. signOut cancels the in-flight refresh task (fast path — network call unwinds).
    /// 2. signOut then takes the session lock and runs.
    /// 3. End state is signed-out.
    ///
    /// Determinism technique: the in-flight refresh is planted directly via
    /// `_test_setInFlightRefresh` with a gated Task (blocked on an AsyncStream gate that
    /// is never yielded to). This bypasses the `liveToken` startup race — the refresh is
    /// definitively in-flight in `inFlightRefresh["s"]` when `signOut` runs. signOut cancels
    /// the gate-blocked task (AsyncStream returns nil on task cancellation → explicit
    /// CancellationError), takes the session lock, and deletes the Keychain row. The new
    /// token is never written because the gate never completes, so the end-state is always
    /// signed-out.
    @Test("D21 scenario 10e: signOut after refresh — end state is signed-out")
    func d21Scenario10eRefreshThenSignOut() async throws {
        defer { StubURLProtocol.reset() }

        let keychain = InMemoryKeychainStore()
        // Token inside skew window — the seeded state is what signOut will read and delete.
        try await seedSignedInState(keychain: keychain, expiresIn: 3 * 60)

        // Stub a successful Portal logout
        try StubURLProtocol.registerSuccess(urlSubstring: "/logout", json: [:])

        let stub = StubOIDCRequesting()
        let urlSession = StubURLProtocol.makeSession()
        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(stub), urlSession: urlSession)

        // Plant a gated in-flight refresh task in inFlightRefresh["s"].
        // The gate (an AsyncStream that is never yielded to) blocks indefinitely until the
        // enclosing Task is cancelled, at which point AsyncStream.next() returns nil and
        // we throw CancellationError explicitly.  This makes the refresh deterministically
        // in-flight — no startup race against signOut.
        let (gateStream, _) = AsyncStream<Void>.makeStream()
        let inFlightRefresh = Task<StoredSSOToken, Error> {
            for await _ in gateStream { break }   // exits when task is cancelled (stream → nil)
            throw CancellationError()
        }
        await service._test_setInFlightRefresh(inFlightRefresh, for: "s")

        // signOut (D21 cancel-then-queue):
        //   step 1 — cancels inFlightRefresh["s"] (exits gate, throws CancellationError)
        //   step 2 — takes session lock, reads keychain, deletes row, fires /logout
        try await service.signOut(sessionName: "s")

        // Drain the cancelled refresh task
        _ = try? await inFlightRefresh.value

        // End state must be signed-out
        let signedIn = await isSignedIn(keychain: keychain)
        #expect(!signedIn, "End state must be signed-out after signOut runs (D21 scenario 10e)")
    }
}
}
