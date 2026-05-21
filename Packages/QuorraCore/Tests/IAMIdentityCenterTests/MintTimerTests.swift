import Testing
import Foundation
@testable import IAMIdentityCenter

extension IAMIdentityCenterTestSuite {
@Suite("Mint timer (T_mint) scheduling (D28)", .serialized, .timeLimit(.minutes(1)))
struct MintTimerTests {

    // MARK: - Helpers

    /// Creates a service backed by the **production** `WallClockSleeper`.
    ///
    /// Use this for tests that only need to verify the timer is *scheduled* (not fired).
    /// Far-future `expiresAt` values keep the timer dormant throughout the test — no real-time wait.
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

    /// Creates a service backed by an injected `MockSleeper`.
    ///
    /// Use this for tests that need `sleep(until:)` to fire deterministically (D19 Sleeper seam).
    private func makeService(
        keychain: InMemoryKeychainStore = InMemoryKeychainStore(),
        portal: StubPortalRequesting = StubPortalRequesting(),
        sleeper: MockSleeper
    ) -> IdentityCenterService {
        return IdentityCenterService(
            keychain: keychain,
            oidcClientProvider: makeStubOIDCProvider(StubOIDCRequesting()),
            portalClient: portal,
            sleeper: sleeper
        )
    }

    /// Seeds a far-future SSO token so `liveToken` returns without triggering a refresh.
    private func seedFreshToken(
        keychain: InMemoryKeychainStore,
        sessionName: String = "s"
    ) async throws {
        try await keychain.writeRecord(
            StoredSSOToken(
                accessToken: "at",
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

    /// Reads the current role-creds row (nil if absent).
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

    // MARK: - scheduleMint schedules a timer (scheduling test)

    @Test("scheduleMint stores a task in mintTimers under the correct key")
    func scheduleMintStoresTimer() async throws {
        defer { StubURLProtocol.reset() }
        // Production WallClockSleeper — far-future expiry keeps the timer dormant.
        let service = makeService()
        let expiresAt = Date().addingTimeInterval(3600)

        await service.scheduleMint(
            forSession: "s",
            accountId: "123456789012",
            roleName: "stub-role",
            region: "us-east-1",
            expiresAt: expiresAt
        )

        let key = "s:123456789012:stub-role"
        let timer = await service.mintTimers[key]
        #expect(timer != nil, "scheduleMint must store a task in mintTimers[key]")
        timer?.cancel()
    }

    // MARK: - T_mint fires at expiresAt − refreshSkew (production skew, deadline check)

    @Test("T_mint sleeps to expiresAt − refreshSkew — the production skew value, not a test-only constant")
    func timerUsesProductionSkewDeadline() async throws {
        defer { StubURLProtocol.reset() }
        // MockSleeper lets the timer fire immediately and records the deadline for assertion (D19).
        let sleeper = MockSleeper()
        let service = makeService(sleeper: sleeper)

        let expiresAt = Date().addingTimeInterval(3600)
        let expectedDeadline = expiresAt.addingTimeInterval(-IdentityCenterService.ServiceConstants.refreshSkew)

        await service.scheduleMint(
            forSession: "s",
            accountId: "123456789012",
            roleName: "stub-role",
            region: "us-east-1",
            expiresAt: expiresAt
        )

        // Wait for the timer task to call sleeper.sleep(until:). MockSleeper auto-advances
        // synthetic time to the deadline and signals waitForNextSleep() waiters. The whole
        // point of the Sleeper seam (D19): tests can verify the production-skew deadline
        // without waiting real seconds.
        await sleeper.waitForNextSleep()

        // Cancel any further timer activity so we don't trigger an unintended mint chain.
        let key = "s:123456789012:stub-role"
        await service.cancelMint(forKey: key)

        let deadlines = await sleeper.recordedDeadlines
        #expect(
            deadlines.contains(where: { abs($0.timeIntervalSince(expectedDeadline)) < 0.01 }),
            "T_mint must sleep to expiresAt − refreshSkew (\(expectedDeadline)); recorded: \(deadlines)"
        )
    }

    // MARK: - handleMint writes a Keychain row (action test, direct call)

    @Test("handleMint (direct call) fires a mint and writes a fresh row to the Keychain")
    func handleMintWritesKeychainRow() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let portal = StubPortalRequesting()

        try await seedFreshToken(keychain: keychain)

        let minted = makeDefaultMintedCredential(accessKeyId: "ASIAMINTDIRECT00")
        await portal.setNextGetRoleCredentialsResult(.success(minted))

        let service = makeService(keychain: keychain, portal: portal)
        let key = "s:123456789012:stub-role"

        // Call handleMint directly — separate from scheduling so the test is deterministic
        // (no timer/sleep involved). Mirrors spec: "prefer state-mutation/handler-direct tests".
        await service.handleMint(
            sessionName: "s",
            accountId: "123456789012",
            roleName: "stub-role",
            region: "us-east-1",
            key: key
        )

        let stored = await readRoleCreds(keychain: keychain)
        #expect(stored != nil, "handleMint must write a role-creds row to the Keychain")
        #expect(stored?.accessKeyId == "ASIAMINTDIRECT00")

        // Clean up the timer scheduled by runMintBody's success path
        await service.cancelMint(forKey: key)
    }

    // MARK: - handleMint is no-op when inFlightMint is already set

    @Test("handleMint is no-op when inFlightMint[key] is already populated — no Portal call")
    func handleMintIsNoOpWhenInFlight() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let portal = StubPortalRequesting()

        try await seedFreshToken(keychain: keychain)

        let service = makeService(keychain: keychain, portal: portal)
        let key = "s:123456789012:stub-role"

        // Inject a never-completing task into inFlightMint so handleMint sees it as populated.
        // Mirrors _test_setInFlightRefresh usage in RefreshTimerTests (D20 no-op guard pattern).
        let neverTask = Task<RoleCredentials, Error> {
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }
        await service._test_setInFlightMint(neverTask, forKey: key)

        // handleMint should see inFlightMint[key] != nil and no-op immediately
        await service.handleMint(
            sessionName: "s",
            accountId: "123456789012",
            roleName: "stub-role",
            region: "us-east-1",
            key: key
        )

        // No Portal call should have been made (guard short-circuited before reaching Portal).
        let callCount = await portal.getRoleCredentialsCallCount
        #expect(callCount == 0, "handleMint must not call Portal when inFlightMint[key] is set")

        // Clean up the never-completing task
        neverTask.cancel()
        _ = await neverTask.result
        await service._test_clearInFlightMint(forKey: key)
    }

    // MARK: - Successful mint reschedules a fresh T_mint (scheduling test)

    @Test("Successful mint (via liveCredentials) reschedules a new T_mint entry in mintTimers")
    func successfulMintReschedulesMintTimer() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let portal = StubPortalRequesting()

        try await seedFreshToken(keychain: keychain)

        let newMinted = makeDefaultMintedCredential()
        await portal.setNextGetRoleCredentialsResult(.success(newMinted))

        // Production WallClockSleeper — far-future expiresAt on the minted credential keeps
        // the rescheduled timer dormant so it doesn't fire and clear mintTimers[key] during the test.
        let service = makeService(keychain: keychain, portal: portal)

        let key = "s:123456789012:stub-role"
        let timerBefore = await service.mintTimers[key]
        #expect(timerBefore == nil, "No T_mint should exist before the first mint")

        // Trigger a mint via liveCredentials (no cached row → inline mint → runMintBody)
        _ = try await service.liveCredentials(
            forSession: "s",
            accountId: "123456789012",
            roleName: "stub-role",
            region: "us-east-1"
        )

        // runMintBody's success path must have called scheduleMint for the new expiresAt.
        // With WallClockSleeper and a far-future deadline, the timer sits in mintTimers without firing.
        let timerAfter = await service.mintTimers[key]
        #expect(timerAfter != nil, "Successful mint must schedule a T_mint for the tuple")
        timerAfter?.cancel()
    }

    // MARK: - cancelMint removes the timer

    @Test("cancelMint removes the timer entry from mintTimers")
    func cancelMintRemovesTimer() async throws {
        defer { StubURLProtocol.reset() }
        // Production WallClockSleeper — timer won't fire during the test.
        let service = makeService()
        let expiresAt = Date().addingTimeInterval(3600)

        await service.scheduleMint(
            forSession: "s",
            accountId: "123456789012",
            roleName: "stub-role",
            region: "us-east-1",
            expiresAt: expiresAt
        )

        let key = "s:123456789012:stub-role"
        let timerBefore = await service.mintTimers[key]
        #expect(timerBefore != nil)

        await service.cancelMint(forSession: "s", accountId: "123456789012", roleName: "stub-role")

        let timerAfter = await service.mintTimers[key]
        #expect(timerAfter == nil, "cancelMint must nil out mintTimers[key]")
    }

    // MARK: - Immediate fire when expiresAt is within skew (scheduling test)

    @Test("scheduleMint does NOT store a task in mintTimers when expiresAt is inside the skew window")
    func immediateFiringDoesNotStoreTask() async throws {
        defer { StubURLProtocol.reset() }
        let keychain = InMemoryKeychainStore()
        let portal = StubPortalRequesting()

        try await seedFreshToken(keychain: keychain)
        await portal.setNextGetRoleCredentialsResult(.success(makeDefaultMintedCredential()))

        // Production WallClockSleeper — the immediate-fire path never calls sleep(until:), so
        // the timer implementation is irrelevant here; what we're testing is the nil-check guard.
        let service = makeService(keychain: keychain, portal: portal)

        // expiresAt is 2 minutes from now — inside the 5-minute skew window.
        // The `interval <= 0` guard fires a detached Task immediately without storing a timer.
        let expiresAt = Date().addingTimeInterval(2 * 60)

        await service.scheduleMint(
            forSession: "s",
            accountId: "123456789012",
            roleName: "stub-role",
            region: "us-east-1",
            expiresAt: expiresAt
        )

        // The immediate-fire path must NOT store a task in mintTimers (mirrors scheduleRefresh's
        // immediate-fire path in Expiration.swift — the task is detached, no timer-slot used).
        let key = "s:123456789012:stub-role"
        let timer = await service.mintTimers[key]
        #expect(timer == nil, "Immediate-fire path must NOT store a task in mintTimers[key]")
    }

    // MARK: - scheduleMint cancels the previous timer (no double-timer)

    @Test("scheduleMint cancels any existing timer for the same key before scheduling a new one")
    func rescheduleCancelsOldTimer() async throws {
        defer { StubURLProtocol.reset() }
        // Production WallClockSleeper — far-future expiry, timers stay dormant.
        let service = makeService()
        let key = "s:123456789012:stub-role"

        let firstExpiry = Date().addingTimeInterval(3600)
        await service.scheduleMint(
            forSession: "s",
            accountId: "123456789012",
            roleName: "stub-role",
            region: "us-east-1",
            expiresAt: firstExpiry
        )
        let firstTimer = await service.mintTimers[key]
        #expect(firstTimer != nil)

        // Schedule again with a new expiry — old timer should be cancelled and replaced.
        let secondExpiry = Date().addingTimeInterval(7200)
        await service.scheduleMint(
            forSession: "s",
            accountId: "123456789012",
            roleName: "stub-role",
            region: "us-east-1",
            expiresAt: secondExpiry
        )
        let secondTimer = await service.mintTimers[key]
        #expect(secondTimer != nil)

        // Exactly one timer entry — the new one replaced the old (no double-timer).
        let timerCount = await service.mintTimers.count
        #expect(timerCount == 1, "mintTimers must have exactly one entry — the new timer replaces the old one")

        secondTimer?.cancel()
    }
}
}

// MARK: - Test-only IdentityCenterService helpers for MintTimerTests

extension IdentityCenterService {
    /// Test-only: directly injects a task into `inFlightMint` without going through `liveCredentials`.
    /// Used to set up the precondition for `handleMint` no-op tests. Mirrors
    /// `_test_setInFlightRefresh` in TestHelpers.swift.
    func _test_setInFlightMint(_ task: Task<RoleCredentials, Error>, forKey key: String) {
        inFlightMint[key] = task
    }

    /// Test-only: removes a task from `inFlightMint` by key (cleanup after no-op tests).
    func _test_clearInFlightMint(forKey key: String) {
        inFlightMint[key] = nil
    }
}
