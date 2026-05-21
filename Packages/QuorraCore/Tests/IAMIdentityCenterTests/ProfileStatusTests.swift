import Testing
import Foundation
@testable import IAMIdentityCenter

extension IAMIdentityCenterTestSuite {
@Suite("IdentityCenterService.status(forProfile:) (D29)", .serialized, .timeLimit(.minutes(1)))
struct ProfileStatusTests {

    // MARK: - Helpers

    private func makeService(
        keychain: InMemoryKeychainStore = InMemoryKeychainStore()
    ) -> IdentityCenterService {
        return IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(StubOIDCRequesting()))
    }

    private func seedToken(
        keychain: InMemoryKeychainStore,
        sessionName: String = "s",
        refreshToken: String? = "rt",
        expiresIn: TimeInterval = 8 * 3600
    ) async throws {
        try await keychain.writeRecord(
            makeDefaultSSOToken(refreshToken: refreshToken, sessionName: sessionName, expiresIn: expiresIn),
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: sessionName
        )
    }

    private func seedRoleCreds(
        keychain: InMemoryKeychainStore,
        sessionName: String = "s",
        accountId: String = "123456789012",
        roleName: String = "stub-role",
        region: String = "us-east-1",
        expiresIn: TimeInterval = 3600
    ) async throws -> Date {
        let expiresAt = Date().addingTimeInterval(expiresIn)
        let key = "\(sessionName):\(accountId):\(roleName)"
        try await keychain.writeRecord(
            RoleCredentials(
                accessKeyId: "ASIACACHED0000KEY",
                secretAccessKey: "cached-secret",
                sessionToken: "cached-token",
                expiresAt: expiresAt,
                accountId: accountId,
                roleName: roleName,
                region: region,
                sessionName: sessionName,
                issuedAt: Date()
            ),
            service: IdentityCenterService.ServiceConstants.roleCredsService,
            account: key
        )
        return expiresAt
    }

    // MARK: - signedOut → .notSignedIn

    @Test("No SSO token → .notSignedIn")
    func notSignedInWhenNoToken() async {
        let service = makeService()
        let result = await service.status(forProfile: "s", accountId: "123456789012", roleName: "stub-role")
        #expect(result == .notSignedIn(sessionName: "s"))
    }

    // MARK: - expired + !canRefresh → .signInExpired

    @Test("Expired token with no refresh token → .signInExpired")
    func signInExpiredWhenExpiredNoRefresh() async throws {
        let keychain = InMemoryKeychainStore()
        try await seedToken(keychain: keychain, refreshToken: nil, expiresIn: -60)
        let service = makeService(keychain: keychain)

        let result = await service.status(forProfile: "s", accountId: "123456789012", roleName: "stub-role")
        #expect(result == .signInExpired(sessionName: "s"))
    }

    // MARK: - signedIn + cached fresh row → .ready(expiresAt: row deadline)

    @Test("Signed in with a cached role-cred row → .ready(expiresAt: <row deadline>)")
    func readyWithCachedRow() async throws {
        let keychain = InMemoryKeychainStore()
        try await seedToken(keychain: keychain, expiresIn: 8 * 3600)
        let rowExpiry = try await seedRoleCreds(keychain: keychain, expiresIn: 3600)
        let service = makeService(keychain: keychain)

        let result = await service.status(forProfile: "s", accountId: "123456789012", roleName: "stub-role")
        if case .ready(let expiresAt) = result {
            #expect(expiresAt != nil)
            #expect(abs((expiresAt ?? .distantPast).timeIntervalSince(rowExpiry)) < 1)
        } else {
            Issue.record("Expected .ready, got \(result)")
        }
    }

    // MARK: - signedIn + NO cached row → .ready(expiresAt: nil)

    @Test("Signed in with no cached role-cred row → .ready(expiresAt: nil) (mint-on-demand §09)")
    func readyWithNoCachedRow() async throws {
        let keychain = InMemoryKeychainStore()
        try await seedToken(keychain: keychain, expiresIn: 8 * 3600)
        let service = makeService(keychain: keychain)

        let result = await service.status(forProfile: "s", accountId: "123456789012", roleName: "stub-role")
        #expect(result == .ready(expiresAt: nil))
    }

    // MARK: - expired + canRefresh → still .ready (§09: silently refreshable bearer)

    @Test("Expired token but canRefresh=true → .ready (bearer silently refreshable per §09)")
    func readyWhenExpiredButRefreshable() async throws {
        let keychain = InMemoryKeychainStore()
        try await seedToken(keychain: keychain, refreshToken: "rt", expiresIn: -60)
        _ = try await seedRoleCreds(keychain: keychain, expiresIn: 3600)
        let service = makeService(keychain: keychain)

        let result = await service.status(forProfile: "s", accountId: "123456789012", roleName: "stub-role")
        if case .ready = result {
            // expected — expired-but-refreshable bearer still counts as active
        } else {
            Issue.record("Expected .ready, got \(result)")
        }
    }

    // MARK: - D28 opportunistic T_mint schedule

    @Test("D28: signed in + cached row + no existing timer → status schedules T_mint")
    func opportunisticMintSchedule() async throws {
        let keychain = InMemoryKeychainStore()
        try await seedToken(keychain: keychain, expiresIn: 8 * 3600)
        _ = try await seedRoleCreds(keychain: keychain, expiresIn: 3600)
        let service = makeService(keychain: keychain)

        let key = "s:123456789012:stub-role"
        let before = await service.mintTimers[key]
        #expect(before == nil, "Precondition: no T_mint before status(forProfile:)")

        _ = await service.status(forProfile: "s", accountId: "123456789012", roleName: "stub-role")

        let after = await service.mintTimers[key]
        #expect(after != nil, "status(forProfile:) must opportunistically schedule T_mint (D28)")
        after?.cancel()
    }

    @Test("D28: repeated status(forProfile:) does not double-schedule T_mint")
    func opportunisticScheduleIsIdempotent() async throws {
        let keychain = InMemoryKeychainStore()
        try await seedToken(keychain: keychain, expiresIn: 8 * 3600)
        _ = try await seedRoleCreds(keychain: keychain, expiresIn: 3600)
        let service = makeService(keychain: keychain)

        _ = await service.status(forProfile: "s", accountId: "123456789012", roleName: "stub-role")
        _ = await service.status(forProfile: "s", accountId: "123456789012", roleName: "stub-role")
        _ = await service.status(forProfile: "s", accountId: "123456789012", roleName: "stub-role")

        let timerCount = await service.mintTimers.count
        #expect(timerCount == 1, "Repeated status calls must not double-schedule (mirrors A1 noDoubleTimer)")
        let key = "s:123456789012:stub-role"
        await service.mintTimers[key]?.cancel()
    }

    @Test("D28: no cached row → status does NOT schedule T_mint")
    func noScheduleWithoutCachedRow() async throws {
        let keychain = InMemoryKeychainStore()
        try await seedToken(keychain: keychain, expiresIn: 8 * 3600)
        let service = makeService(keychain: keychain)

        _ = await service.status(forProfile: "s", accountId: "123456789012", roleName: "stub-role")

        let key = "s:123456789012:stub-role"
        let timer = await service.mintTimers[key]
        #expect(timer == nil, "No cached row → nothing to pre-warm → no T_mint")
    }

    // MARK: - Helper mapping (D31 matrix — steady states only)

    @Test("ProfileAuthStatus helper mapping matches the D31 matrix for the three steady states")
    func helperMappingMatchesMatrix() {
        let ready = ProfileAuthStatus.ready(expiresAt: Date().addingTimeInterval(3600))
        #expect(ready.symbolName == "person.icloud.fill")
        #expect(ready.foregroundRole == .green)
        #expect(ready.statusEffect == nil)
        #expect(ready.accessibilityPhrase.contains("active"))

        let notSignedIn = ProfileAuthStatus.notSignedIn(sessionName: "s")
        #expect(notSignedIn.symbolName == "person.icloud")
        #expect(notSignedIn.foregroundRole == .secondary)
        #expect(notSignedIn.statusEffect == nil)
        #expect(notSignedIn.accessibilityPhrase.contains("sign in required"))

        let expired = ProfileAuthStatus.signInExpired(sessionName: "s")
        #expect(expired.symbolName == "person.icloud")
        #expect(expired.foregroundRole == .red)
        #expect(expired.statusEffect == nil)
        #expect(expired.accessibilityPhrase.contains("sign in required"))
    }

    @Test("ready(expiresAt: nil) accessibility phrase is the no-deadline variant")
    func readyNilExpiryPhrase() {
        let ready = ProfileAuthStatus.ready(expiresAt: nil)
        #expect(ready.accessibilityPhrase == "active, credentials ready")
    }
}
}
