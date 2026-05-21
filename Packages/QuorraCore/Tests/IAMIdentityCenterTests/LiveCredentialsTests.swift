import Testing
import Foundation
@testable import IAMIdentityCenter

extension IAMIdentityCenterTestSuite {
@Suite("liveCredentials (D25, D26)", .serialized, .timeLimit(.minutes(1)))
struct LiveCredentialsTests {

    // MARK: - Helpers

    /// Creates a service wired to an injected `StubPortalRequesting` for actor-behavior tests.
    ///
    /// The `OIDCClient` is pointed at a StubURLProtocol session so `liveToken`'s inline refresh
    /// path (when triggered) doesn't escape to the real network. Tests that only need the cached
    /// path seed a far-future token so `liveToken` returns immediately without a refresh attempt.
    private func makeService(
        keychain: InMemoryKeychainStore = InMemoryKeychainStore(),
        portal: StubPortalRequesting = StubPortalRequesting()
    ) -> IdentityCenterService {
        return IdentityCenterService(
            keychain: keychain,
            oidcClientProvider: makeStubOIDCProvider(StubOIDCRequesting()),
            portalClient: portal
        )
    }

    /// Seeds a fresh SSO token (far-future expiry) so `liveToken` returns immediately.
    private func seedFreshToken(
        keychain: InMemoryKeychainStore,
        sessionName: String = "s",
        accessToken: String = "at"
    ) async throws {
        try await keychain.writeRecord(
            StoredSSOToken(
                accessToken: accessToken,
                expiresAt: Date().addingTimeInterval(8 * 3600),
                refreshToken: "rt",
                issuedAt: Date(),
                region: "us-east-1",
                sessionName: sessionName
            ),
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: sessionName
        )
    }

    /// Seeds a `RoleCredentials` row into the keychain.
    private func seedRoleCreds(
        keychain: InMemoryKeychainStore,
        sessionName: String = "s",
        accountId: String = "123456789012",
        roleName: String = "stub-role",
        region: String = "us-east-1",
        expiresIn: TimeInterval = 3600
    ) async throws {
        let key = "\(sessionName):\(accountId):\(roleName)"
        let creds = RoleCredentials(
            accessKeyId: "ASIACACHED0000KEY",
            secretAccessKey: "cached-secret",
            sessionToken: "cached-token",
            expiresAt: Date().addingTimeInterval(expiresIn),
            accountId: accountId,
            roleName: roleName,
            region: region,
            sessionName: sessionName,
            issuedAt: Date()
        )
        try await keychain.writeRecord(
            creds,
            service: IdentityCenterService.ServiceConstants.roleCredsService,
            account: key
        )
    }

    /// Reads the current role creds row from the keychain (returns nil if absent).
    private func readRoleCreds(
        keychain: InMemoryKeychainStore,
        sessionName: String = "s",
        accountId: String = "123456789012",
        roleName: String = "stub-role"
    ) async -> RoleCredentials? {
        let key = "\(sessionName):\(accountId):\(roleName)"
        return try? await keychain.readRecord(
            RoleCredentials.self,
            service: IdentityCenterService.ServiceConstants.roleCredsService,
            account: key
        )
    }

    // MARK: - D26: Cached-fresh → return cached (no Portal call)

    @Test("liveCredentials returns cached row when outside skew window (no Portal call)")
    func cachedFreshReturnsCachedNoPortalCall() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let portal = StubPortalRequesting()

        try await seedFreshToken(keychain: keychain)
        // Seed a role creds row with far-future expiry
        try await seedRoleCreds(keychain: keychain, expiresIn: 2 * 3600)

        let service = makeService(keychain: keychain, portal: portal)
        let creds = try await service.liveCredentials(
            forSession: "s",
            accountId: "123456789012",
            roleName: "stub-role",
            region: "us-east-1"
        )

        // Returns the cached credentials
        #expect(creds.accessKeyId == "ASIACACHED0000KEY")
        // No Portal call was made
        let callCount = await portal.getRoleCredentialsCallCount
        #expect(callCount == 0)
    }

    // MARK: - D26: Inside skew → inline mint

    @Test("liveCredentials triggers inline mint when cached row is inside skew window")
    func insideSkewWindowTriggersMint() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let portal = StubPortalRequesting()

        try await seedFreshToken(keychain: keychain)
        // Seed a row that expires in 3 minutes (inside the 5-min skew)
        try await seedRoleCreds(keychain: keychain, expiresIn: 3 * 60)

        let newMinted = makeDefaultMintedCredential()
        await portal.setNextGetRoleCredentialsResult(.success(newMinted))

        let service = makeService(keychain: keychain, portal: portal)
        let creds = try await service.liveCredentials(
            forSession: "s",
            accountId: "123456789012",
            roleName: "stub-role",
            region: "us-east-1"
        )

        // Should have minted new credentials (not the cached ones)
        #expect(creds.accessKeyId == newMinted.accessKeyId)
        let callCount = await portal.getRoleCredentialsCallCount
        #expect(callCount == 1)
    }

    // MARK: - D26: Past expiry, bearer valid → inline mint

    @Test("liveCredentials triggers inline mint when cached row is past expiresAt")
    func pastExpiryTriggersMint() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let portal = StubPortalRequesting()

        try await seedFreshToken(keychain: keychain)
        // Seed a row 60 seconds in the past
        try await seedRoleCreds(keychain: keychain, expiresIn: -60)

        let newMinted = makeDefaultMintedCredential()
        await portal.setNextGetRoleCredentialsResult(.success(newMinted))

        let service = makeService(keychain: keychain, portal: portal)
        let creds = try await service.liveCredentials(
            forSession: "s",
            accountId: "123456789012",
            roleName: "stub-role",
            region: "us-east-1"
        )

        #expect(creds.accessKeyId == newMinted.accessKeyId)
        let callCount = await portal.getRoleCredentialsCallCount
        #expect(callCount == 1)
    }

    // MARK: - D26: No cached row → inline mint

    @Test("liveCredentials mints when no cached row exists")
    func noCachedRowTriggersMint() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let portal = StubPortalRequesting()

        try await seedFreshToken(keychain: keychain)
        // No role creds row seeded

        let newMinted = makeDefaultMintedCredential()
        await portal.setNextGetRoleCredentialsResult(.success(newMinted))

        let service = makeService(keychain: keychain, portal: portal)
        let creds = try await service.liveCredentials(
            forSession: "s",
            accountId: "123456789012",
            roleName: "stub-role",
            region: "us-east-1"
        )

        #expect(creds.accessKeyId == newMinted.accessKeyId)
        let callCount = await portal.getRoleCredentialsCallCount
        #expect(callCount == 1)
    }

    // MARK: - D26: Correct provenance (amendment guard)

    @Test("liveCredentials constructs RoleCredentials with correct sessionName provenance")
    func constructedCredsHaveCorrectSessionName() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let portal = StubPortalRequesting()

        // Use a distinctive session name to guard the amendment bug
        let sessionName = "my-distinct-session"
        try await seedFreshToken(keychain: keychain, sessionName: sessionName)

        let newMinted = makeDefaultMintedCredential()
        await portal.setNextGetRoleCredentialsResult(.success(newMinted))

        let service = makeService(keychain: keychain, portal: portal)
        let creds = try await service.liveCredentials(
            forSession: sessionName,
            accountId: "999888777666",
            roleName: "AdminRole",
            region: "eu-west-1"
        )

        // All provenance fields must match what was passed in — NOT defaults or empty string
        #expect(creds.sessionName == sessionName, "sessionName must be the caller-supplied value, not empty")
        #expect(creds.accountId == "999888777666")
        #expect(creds.roleName == "AdminRole")
        #expect(creds.region == "eu-west-1")
        // AWS-supplied fields come from the minted credential
        #expect(creds.accessKeyId == newMinted.accessKeyId)
        #expect(creds.secretAccessKey == newMinted.secretAccessKey)
        #expect(creds.sessionToken == newMinted.sessionToken)
        #expect(creds.expiresAt == newMinted.expiresAt)
    }

    // MARK: - D26: Mint persists to Keychain

    @Test("Successful liveCredentials mint writes new row to Keychain")
    func successfulMintWritesToKeychain() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let portal = StubPortalRequesting()

        try await seedFreshToken(keychain: keychain)

        let newMinted = makeDefaultMintedCredential(accessKeyId: "ASIAWRITTENKEY0")
        await portal.setNextGetRoleCredentialsResult(.success(newMinted))

        let service = makeService(keychain: keychain, portal: portal)
        _ = try await service.liveCredentials(
            forSession: "s",
            accountId: "123456789012",
            roleName: "stub-role",
            region: "us-east-1"
        )

        // Verify the Keychain row was written
        let stored = await readRoleCreds(keychain: keychain)
        #expect(stored != nil)
        #expect(stored?.accessKeyId == "ASIAWRITTENKEY0")
        #expect(stored?.sessionName == "s")
    }

    // MARK: - D26: Concurrent calls coalesce — one Portal call

    @Test("Concurrent liveCredentials calls coalesce — only one Portal call is made")
    func concurrentCallsCoalesce() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let portal = StubPortalRequesting()

        try await seedFreshToken(keychain: keychain)
        // No cached row — both concurrent calls will need to mint

        // Use a suspending gate so both tasks are in flight simultaneously before the mint completes.
        // We avoid NSLock (unavailable in async contexts under Swift 6 strict concurrency);
        // the portal actor's built-in getRoleCredentialsCallCount is the assertion vehicle.
        let (gateStream, gateContinuation) = AsyncStream<Void>.makeStream()

        await portal.setGetRoleCredentialsBlock {
            // Suspend until the test unblocks — gives the second concurrent call time to coalesce
            for await _ in gateStream { break }
            return makeDefaultMintedCredential()
        }

        let service = makeService(keychain: keychain, portal: portal)

        // Fire two concurrent liveCredentials calls for the same tuple
        async let c1 = service.liveCredentials(
            forSession: "s",
            accountId: "123456789012",
            roleName: "stub-role",
            region: "us-east-1"
        )
        async let c2 = service.liveCredentials(
            forSession: "s",
            accountId: "123456789012",
            roleName: "stub-role",
            region: "us-east-1"
        )

        // Yield control so both async tasks can progress to the suspension point
        await Task.yield()
        // Unblock the gate — the coalesced task completes
        gateContinuation.yield(())
        gateContinuation.finish()

        let (creds1, creds2) = try await (c1, c2)

        // Both should succeed with the same result
        #expect(creds1.accessKeyId == creds2.accessKeyId)

        // Exactly ONE Portal call should have been made (D26 coalescing)
        let callCount = await portal.getRoleCredentialsCallCount
        #expect(callCount == 1)
    }

    // MARK: - D26: .notSignedIn propagates

    @Test("liveCredentials propagates .notSignedIn when no SSO token exists")
    func notSignedInPropagates() async throws {
        defer { StubURLProtocol.reset() }
        // Empty keychain — no SSO token
        let keychain = InMemoryKeychainStore()
        let portal = StubPortalRequesting()
        let service = makeService(keychain: keychain, portal: portal)

        do {
            _ = try await service.liveCredentials(
                forSession: "s",
                accountId: "123456789012",
                roleName: "stub-role",
                region: "us-east-1"
            )
            Issue.record("Expected .notSignedIn to be thrown")
        } catch IAMIdentityCenterError.notSignedIn {
            // expected
        } catch {
            Issue.record("Wrong error: \(error)")
        }

        // No Portal call should have been made
        let callCount = await portal.getRoleCredentialsCallCount
        #expect(callCount == 0)
    }

    // MARK: - D26: ForbiddenException → .roleNotAssigned + cached row purged

    @Test("ForbiddenException throws .roleNotAssigned and purges cached row from Keychain")
    func forbiddenExceptionPurgesCachedRow() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let portal = StubPortalRequesting()

        try await seedFreshToken(keychain: keychain)
        // Seed a stale (expired) cached row so we exercise the purge path
        try await seedRoleCreds(keychain: keychain, expiresIn: -60)

        await portal.setNextGetRoleCredentialsResult(.failure(IAMIdentityCenterError.roleNotAssigned))

        let service = makeService(keychain: keychain, portal: portal)

        do {
            _ = try await service.liveCredentials(
                forSession: "s",
                accountId: "123456789012",
                roleName: "stub-role",
                region: "us-east-1"
            )
            Issue.record("Expected .roleNotAssigned to be thrown")
        } catch IAMIdentityCenterError.roleNotAssigned {
            // expected
        } catch {
            Issue.record("Wrong error: \(error)")
        }

        // The cached row must have been purged
        let stored = await readRoleCreds(keychain: keychain)
        #expect(stored == nil, "Cached role creds row should be purged after .roleNotAssigned")
    }

    // MARK: - D26: ResourceNotFoundException → .accountNotFound + cached row purged

    @Test("ResourceNotFoundException throws .accountNotFound and purges cached row from Keychain")
    func resourceNotFoundPurgesCachedRow() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let portal = StubPortalRequesting()

        try await seedFreshToken(keychain: keychain)
        try await seedRoleCreds(keychain: keychain, expiresIn: -60)

        await portal.setNextGetRoleCredentialsResult(.failure(IAMIdentityCenterError.accountNotFound))

        let service = makeService(keychain: keychain, portal: portal)

        do {
            _ = try await service.liveCredentials(
                forSession: "s",
                accountId: "123456789012",
                roleName: "stub-role",
                region: "us-east-1"
            )
            Issue.record("Expected .accountNotFound to be thrown")
        } catch IAMIdentityCenterError.accountNotFound {
            // expected
        } catch {
            Issue.record("Wrong error: \(error)")
        }

        let stored = await readRoleCreds(keychain: keychain)
        #expect(stored == nil, "Cached role creds row should be purged after .accountNotFound")
    }

    // MARK: - D26: Transient error → propagates, Keychain row NOT purged

    @Test("Transient network error propagates without purging the cached Keychain row")
    func transientErrorDoesNotPurgeCachedRow() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let portal = StubPortalRequesting()

        try await seedFreshToken(keychain: keychain)
        // Seed a stale cached row
        try await seedRoleCreds(keychain: keychain, expiresIn: -60)

        // Transient error (network-level)
        let networkError = URLError(.notConnectedToInternet)
        await portal.setNextGetRoleCredentialsResult(.failure(IAMIdentityCenterError.network(networkError)))

        let service = makeService(keychain: keychain, portal: portal)

        do {
            _ = try await service.liveCredentials(
                forSession: "s",
                accountId: "123456789012",
                roleName: "stub-role",
                region: "us-east-1"
            )
            Issue.record("Expected network error to be thrown")
        } catch IAMIdentityCenterError.network {
            // expected
        } catch {
            Issue.record("Wrong error: \(error)")
        }

        // The cached row must NOT have been purged (transient failure)
        let stored = await readRoleCreds(keychain: keychain)
        #expect(stored != nil, "Cached role creds row should NOT be purged after a transient error")
    }

    // MARK: - D26: Different tuples don't block each other

    @Test("Concurrent liveCredentials calls for different tuples proceed independently")
    func differentTuplesDoNotBlock() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let portal = StubPortalRequesting()

        try await seedFreshToken(keychain: keychain)
        // Seed fresh token for a second session too
        try await seedFreshToken(keychain: keychain, sessionName: "s2", accessToken: "at2")

        let minted1 = makeDefaultMintedCredential(accessKeyId: "ASIATUPLEONE000")
        let minted2 = makeDefaultMintedCredential(accessKeyId: "ASIATUPLETWO000")

        // First call gets minted1, second gets minted2
        await portal.setNextGetRoleCredentialsResult(.success(minted1))

        let service = makeService(keychain: keychain, portal: portal)

        // Call for tuple 1
        let creds1 = try await service.liveCredentials(
            forSession: "s",
            accountId: "111111111111",
            roleName: "Role1",
            region: "us-east-1"
        )

        // Update stub for second call
        await portal.setNextGetRoleCredentialsResult(.success(minted2))

        // Call for tuple 2 (different session)
        let creds2 = try await service.liveCredentials(
            forSession: "s2",
            accountId: "222222222222",
            roleName: "Role2",
            region: "us-west-2"
        )

        #expect(creds1.accessKeyId == "ASIATUPLEONE000")
        #expect(creds2.accessKeyId == "ASIATUPLETWO000")
        #expect(creds1.sessionName == "s")
        #expect(creds2.sessionName == "s2")
    }
}
}
