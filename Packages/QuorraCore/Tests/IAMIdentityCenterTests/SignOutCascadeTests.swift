import Testing
import Foundation
@testable import IAMIdentityCenter

extension IAMIdentityCenterTestSuite {
@Suite("Sign-out cascade (D27)", .serialized, .timeLimit(.minutes(1)))
struct SignOutCascadeTests {

    // MARK: - Helpers

    private func makeService(
        keychain: InMemoryKeychainStore = InMemoryKeychainStore(),
        portal: StubPortalRequesting = StubPortalRequesting()
    ) -> IdentityCenterService {
        return IdentityCenterService(
            keychain: keychain,
            oidcClientProvider: makeStubOIDCProvider(StubOIDCRequesting()),
            portalClient: portal,
            urlSession: StubURLProtocol.makeSession()
        )
    }

    /// Seeds a fresh SSO token (far-future expiry) so `liveToken` returns without a refresh.
    private func seedFreshToken(
        keychain: InMemoryKeychainStore,
        sessionName: String = "session-a"
    ) async throws {
        try await keychain.writeRecord(
            StoredSSOToken(
                accessToken: "test-access-token",
                expiresAt: Date().addingTimeInterval(8 * 3600),
                refreshToken: nil,
                issuedAt: Date(),
                region: "us-east-1",
                sessionName: sessionName
            ),
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: sessionName
        )
    }

    /// Seeds a role-cred row for the given (sessionName, accountId, roleName) tuple.
    private func seedRoleCreds(
        keychain: InMemoryKeychainStore,
        sessionName: String,
        accountId: String = "123456789012",
        roleName: String = "stub-role"
    ) async throws {
        let key = "\(sessionName):\(accountId):\(roleName)"
        let creds = RoleCredentials(
            accessKeyId: "ASIASTUB0000KEY",
            secretAccessKey: "stub-secret",
            sessionToken: "stub-token",
            expiresAt: Date().addingTimeInterval(3600),
            accountId: accountId,
            roleName: roleName,
            region: "us-east-1",
            sessionName: sessionName,
            issuedAt: Date()
        )
        try await keychain.writeRecord(
            creds,
            service: IdentityCenterService.ServiceConstants.roleCredsService,
            account: key
        )
    }

    /// Returns the role-cred account keys present in the keychain for `roleCredsService`.
    private func roleCredKeys(keychain: InMemoryKeychainStore) async -> [String] {
        (try? await keychain.enumerateAccounts(
            service: IdentityCenterService.ServiceConstants.roleCredsService
        )) ?? []
    }

    // MARK: - D27: Role-cred purge, cross-session isolation

    /// Signs out session A; asserts all of A's role-cred rows are gone and session B's row survives.
    @Test("Sign-out purges all role-cred rows for the session while leaving other sessions' rows intact")
    func signOutPurgesRoleCredRowsWithCrossSessionIsolation() async throws {
        defer { StubURLProtocol.reset() }

        let keychain = InMemoryKeychainStore()
        let service = makeService(keychain: keychain)

        // Seed SSO token for session A
        try await seedFreshToken(keychain: keychain, sessionName: "session-a")

        // Seed two role-cred rows for session A (different roles)
        try await seedRoleCreds(keychain: keychain, sessionName: "session-a", accountId: "111111111111", roleName: "RoleOne")
        try await seedRoleCreds(keychain: keychain, sessionName: "session-a", accountId: "111111111111", roleName: "RoleTwo")

        // Seed one role-cred row for a DIFFERENT session (must survive)
        try await seedRoleCreds(keychain: keychain, sessionName: "session-b", accountId: "222222222222", roleName: "OtherRole")

        // Stub /logout success
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

        try await service.signOut(sessionName: "session-a")

        let remaining = await roleCredKeys(keychain: keychain)

        // Both session-a rows must be purged
        #expect(
            !remaining.contains("session-a:111111111111:RoleOne"),
            "session-a RoleOne row must be purged on sign-out"
        )
        #expect(
            !remaining.contains("session-a:111111111111:RoleTwo"),
            "session-a RoleTwo row must be purged on sign-out"
        )

        // session-b row must survive (prefix filter isolates session-a only)
        #expect(
            remaining.contains("session-b:222222222222:OtherRole"),
            "session-b row must NOT be purged when signing out session-a"
        )
    }

    // MARK: - D27: In-flight mint cancelled on sign-out

    /// Plants a long-sleeping inFlightMint for session A, signs out, asserts the task is cancelled
    /// and no fresh Keychain row was written by it.
    ///
    /// Uses `Task.sleep(for:)` — a cooperative cancellation point — so the task exits with
    /// `CancellationError` when `cancel()` is called before the sleep completes. This mirrors
    /// how a real in-flight Portal call unwinds on cancellation (URLSession tasks throw
    /// `CancellationError` cooperatively on the next suspension point).
    @Test("Sign-out cancels in-flight mints for the session; cancelled mint writes no Keychain row")
    func signOutCancelsInFlightMints() async throws {
        defer { StubURLProtocol.reset() }

        let keychain = InMemoryKeychainStore()
        let service = makeService(keychain: keychain)

        // Seed SSO token so signOut has a valid token to delete
        try await seedFreshToken(keychain: keychain, sessionName: "session-a")

        // Construct the in-flight mint key for session-a
        let mintKey = "session-a:111111111111:stub-role"

        // Plant a long-sleeping task that mimics an in-flight Portal call.
        // Task.sleep(for:) is a cooperative cancellation point — cancelling the task before
        // the sleep completes causes it to throw CancellationError. No Keychain write happens.
        let mintTask = Task<RoleCredentials, Error> {
            try await Task.sleep(for: .seconds(60))
            // If we reach here, the sleep was NOT cancelled — test will fail via assertion below
            return makeDefaultRoleCredentials(sessionName: "session-a")
        }
        await service._test_setInFlightMint(mintTask, forKey: mintKey)

        // Stub /logout so signOut completes cleanly
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

        // Sign out — the pre-lock step (D27 step 1 extension) cancels inFlightMint["session-a:..."]
        try await service.signOut(sessionName: "session-a")

        // Await the mint task — it must have completed with CancellationError.
        // `await mintTask.result` blocks until the task finishes (which it will promptly,
        // since cancel() unwinds Task.sleep cooperatively).
        let result = await mintTask.result
        switch result {
        case .failure(let error) where error is CancellationError:
            break  // expected — the cancel() call propagated through Task.sleep
        case .failure(let error):
            Issue.record("Expected CancellationError from mint task, got \(error)")
        case .success:
            Issue.record("Mint task should have been cancelled, not succeeded")
        }

        // No role-cred Keychain row must have been written for the cancelled mint
        let stored = try? await keychain.readRecord(
            RoleCredentials.self,
            service: IdentityCenterService.ServiceConstants.roleCredsService,
            account: mintKey
        )
        #expect(stored == nil, "Cancelled mint must not write a role-cred row to the Keychain")
    }

    // MARK: - D27: T_mint cancelled on sign-out

    /// Seeds a far-future T_mint for session A, signs out, asserts mintTimers[key] is nil.
    @Test("Sign-out cancels T_mint timers for the session")
    func signOutCancelsMintTimers() async throws {
        defer { StubURLProtocol.reset() }

        let keychain = InMemoryKeychainStore()
        let service = makeService(keychain: keychain)

        // Seed SSO token
        try await seedFreshToken(keychain: keychain, sessionName: "session-a")

        // Schedule a far-future T_mint (WallClockSleeper default — won't fire during test)
        let mintKey = "session-a:111111111111:stub-role"
        let farFuture = Date().addingTimeInterval(3600)
        await service.scheduleMint(
            forSession: "session-a",
            accountId: "111111111111",
            roleName: "stub-role",
            region: "us-east-1",
            expiresAt: farFuture
        )

        // Verify the timer was stored
        let timerBefore = await service.mintTimers[mintKey]
        #expect(timerBefore != nil, "T_mint must be present before sign-out")

        // Stub /logout
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

        try await service.signOut(sessionName: "session-a")

        let timerAfter = await service.mintTimers[mintKey]
        #expect(timerAfter == nil, "Sign-out must cancel and remove T_mint for session-a")
    }

    // MARK: - D27: Idempotent-missing-token path still purges role-cred rows

    /// No SSO token exists; role-cred rows are present.
    /// Sign-out (idempotent path) must still purge those rows.
    @Test("Idempotent sign-out (no SSO token) still purges role-cred rows for the session")
    func idempotentSignOutPurgesRoleCredRows() async throws {
        defer { StubURLProtocol.reset() }

        let keychain = InMemoryKeychainStore()
        let service = makeService(keychain: keychain)

        // NO SSO token — triggers the idempotent early-return path inside the lock
        // But seed role-cred rows that must still be purged (the D27 security-critical case)
        try await seedRoleCreds(keychain: keychain, sessionName: "session-a", accountId: "111111111111", roleName: "RoleOne")
        try await seedRoleCreds(keychain: keychain, sessionName: "session-a", accountId: "111111111111", roleName: "RoleTwo")

        // session-b row must survive
        try await seedRoleCreds(keychain: keychain, sessionName: "session-b", accountId: "222222222222", roleName: "OtherRole")

        // signOut should NOT throw on missing token — it's idempotent
        try await service.signOut(sessionName: "session-a")

        let remaining = await roleCredKeys(keychain: keychain)

        // session-a rows must be purged even though there was no SSO token
        #expect(
            !remaining.contains("session-a:111111111111:RoleOne"),
            "Idempotent sign-out must still purge session-a RoleOne row"
        )
        #expect(
            !remaining.contains("session-a:111111111111:RoleTwo"),
            "Idempotent sign-out must still purge session-a RoleTwo row"
        )

        // session-b row must survive
        #expect(
            remaining.contains("session-b:222222222222:OtherRole"),
            "session-b row must NOT be purged by an idempotent sign-out of session-a"
        )
    }
}
}
