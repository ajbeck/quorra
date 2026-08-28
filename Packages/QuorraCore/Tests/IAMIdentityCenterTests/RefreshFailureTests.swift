import Testing
import Foundation
@testable import IAMIdentityCenter

extension IAMIdentityCenterTestSuite {
@Suite("Refresh failure handling (D14)", .serialized, .timeLimit(.minutes(1)))
struct RefreshFailureTests {

    // MARK: - Helpers

    private func makeService(
        keychain: InMemoryKeychainStore = InMemoryKeychainStore(),
        stub: StubOIDCRequesting = StubOIDCRequesting()
    ) -> IdentityCenterService {
        IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(stub))
    }

    private func seedToken(
        keychain: InMemoryKeychainStore,
        expiresAt: Date,
        refreshToken: String? = "rt",
        sessionName: String = "s"
    ) async throws {
        try await keychain.writeRecord(
            StoredSSOToken(
                accessToken: "at",
                expiresAt: expiresAt,
                refreshToken: refreshToken,
                issuedAt: Date(),
                region: "us-east-1",
                sessionName: sessionName
            ),
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: sessionName
        )
    }

    private func seedOIDCClient(keychain: InMemoryKeychainStore, region: String = "us-east-1") async throws {
        try await keychain.writeRecord(
            StoredOIDCClient(
                clientId: "cid",
                clientSecret: "cs",
                issuedAt: Date(),
                secretExpiresAt: Date().addingTimeInterval(90 * 24 * 60 * 60),
                region: region,
                scopes: ["sso:account:access"]
            ),
            service: IdentityCenterService.ServiceConstants.oidcClientService,
            account: region
        )
    }

    // Reads the stored token back from the in-memory keychain
    private func readToken(keychain: InMemoryKeychainStore, sessionName: String = "s") async throws -> StoredSSOToken {
        try await keychain.readRecord(
            StoredSSOToken.self,
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: sessionName
        )
    }

    // MARK: - Terminal bucket: nils refreshToken in Keychain, emits .refreshFailed, cancels T_refresh
    //
    // `invalid_grant` → .refreshTokenRejected and `invalid_client` → .refreshClientInvalid exercise
    // the same nil-wipe code path. A single parameterized test covers both error codes plus
    // the timer-cancel and event assertions that would otherwise be separate tests.

    @Test(
        "Terminal failure nils refreshToken in Keychain, cancels T_refresh, emits .refreshFailed",
        arguments: [
            IAMIdentityCenterError.refreshTokenRejected,
            IAMIdentityCenterError.refreshClientInvalid,
        ]
    )
    func terminalFailureNilsRefreshToken(expectedError: IAMIdentityCenterError) async throws {
        let keychain = InMemoryKeychainStore()
        // Inside skew so liveToken triggers inline refresh
        let expiresAt = Date().addingTimeInterval(3 * 60)
        try await seedToken(keychain: keychain, expiresAt: expiresAt, refreshToken: "rt")
        try await seedOIDCClient(keychain: keychain)

        // The SDK adapter remaps invalid_grant → .refreshTokenRejected and
        // invalid_client → .refreshClientInvalid; the stub stands in for that output.
        let stub = StubOIDCRequesting()
        await stub.setNextRefreshResult(.failure(expectedError))

        let service = makeService(keychain: keychain, stub: stub)

        // Await the expected event instead of assuming one scheduler yield is enough for
        // the stream consumer to run under the full test suite.
        let eventTask = Task { () -> Bool in
            for await event in service.events {
                if case .refreshFailed(let sessionName) = event, sessionName == "s" {
                    return true
                }
            }
            return false
        }
        defer { eventTask.cancel() }

        // Pre-seed a refresh timer so we can verify it gets cancelled
        let farFuture = Date().addingTimeInterval(2 * 3600)
        await service.scheduleRefresh(forSession: "s", expiresAt: farFuture)
        #expect(await service.refreshTimers["s"] != nil, "Precondition: refresh timer must be seeded")

        do {
            _ = try await service.liveToken(forSession: "s")
            Issue.record("Expected \(expectedError) to be thrown")
        } catch let err as IAMIdentityCenterError {
            #expect(err == expectedError)
        }

        // Keychain row: refreshToken nil, accessToken preserved
        let stored = try await readToken(keychain: keychain)
        #expect(stored.refreshToken == nil)
        #expect(stored.accessToken == "at")

        // T_refresh cancelled after terminal failure
        #expect(await service.refreshTimers["s"] == nil)

        // .refreshFailed event emitted
        let didReceiveRefreshFailure = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask { await eventTask.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
                return false
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        #expect(didReceiveRefreshFailure)
    }

    // MARK: - Transient bucket: a non-terminal error leaves Keychain unchanged
    //
    // Post-SDK-migration a transient transport/server failure surfaces as `.awsError`
    // (the adapter maps unrecognized SDK errors and InternalServerException there), not as
    // the old `.network` / `.httpStatus` cases. The failure-bucketing contract is unchanged:
    // anything that is NOT .refreshTokenRejected / .refreshClientInvalid is transient and must
    // leave the stored refresh token intact.

    @Test("Transient error leaves Keychain refresh token intact (no terminal wipe)")
    func transientErrorLeavesKeychainUnchanged() async throws {
        let keychain = InMemoryKeychainStore()
        let expiresAt = Date().addingTimeInterval(3 * 60)
        try await seedToken(keychain: keychain, expiresAt: expiresAt, refreshToken: "rt")
        try await seedOIDCClient(keychain: keychain)

        let stub = StubOIDCRequesting()
        await stub.setNextRefreshResult(.failure(IAMIdentityCenterError.awsError(code: "server_error", description: nil)))

        let service = makeService(keychain: keychain, stub: stub)
        _ = try? await service.liveToken(forSession: "s")

        let stored = try await readToken(keychain: keychain)
        // Transient failure: refresh token must NOT have been wiped
        #expect(stored.refreshToken == "rt")
    }

    @Test("Transient error propagates (not terminal) from liveToken")
    func transientErrorPropagatesFromLiveToken() async throws {
        let keychain = InMemoryKeychainStore()
        let expiresAt = Date().addingTimeInterval(3 * 60)
        try await seedToken(keychain: keychain, expiresAt: expiresAt, refreshToken: "rt")
        try await seedOIDCClient(keychain: keychain)

        let stub = StubOIDCRequesting()
        await stub.setNextRefreshResult(.failure(IAMIdentityCenterError.awsError(code: "server_error", description: nil)))

        let service = makeService(keychain: keychain, stub: stub)
        do {
            _ = try await service.liveToken(forSession: "s")
            Issue.record("Expected a transient error to be thrown")
        } catch IAMIdentityCenterError.awsError(let code, _) {
            #expect(code == "server_error")
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    // MARK: - No auto-retry

    @Test("No auto-retry on transient failure — exactly one refresh call is made")
    func noAutoRetryOnTransientFailure() async throws {
        let keychain = InMemoryKeychainStore()
        let expiresAt = Date().addingTimeInterval(3 * 60)
        try await seedToken(keychain: keychain, expiresAt: expiresAt, refreshToken: "rt")
        try await seedOIDCClient(keychain: keychain)

        let stub = StubOIDCRequesting()
        await stub.setNextRefreshResult(.failure(IAMIdentityCenterError.awsError(code: "server_error", description: nil)))

        let service = makeService(keychain: keychain, stub: stub)
        _ = try? await service.liveToken(forSession: "s")

        // Must be exactly 1 — no retry loop
        #expect(await stub.refreshCallCount == 1)
    }

    // MARK: - T_expire left running after failure

    @Test("Expiration timer continues running after a transient refresh failure")
    func expirationTimerRunsAfterTransientFailure() async throws {
        let keychain = InMemoryKeychainStore()
        let expiresAt = Date().addingTimeInterval(3 * 60)
        try await seedToken(keychain: keychain, expiresAt: expiresAt, refreshToken: "rt")
        try await seedOIDCClient(keychain: keychain)

        let stub = StubOIDCRequesting()
        await stub.setNextRefreshResult(.failure(IAMIdentityCenterError.awsError(code: "server_error", description: nil)))

        let service = makeService(keychain: keychain, stub: stub)
        // Seed expiration timer first
        await service.scheduleExpiration(forSession: "s", expiresAt: expiresAt)
        #expect(await service.expirationTimers["s"] != nil)

        _ = try? await service.liveToken(forSession: "s")

        // T_expire should still be running
        #expect(await service.expirationTimers["s"] != nil)
        // Tidy up
        await service.expirationTimers["s"]?.cancel()
    }
}
}
