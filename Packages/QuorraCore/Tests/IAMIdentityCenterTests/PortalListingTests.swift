import Testing
import Foundation
@testable import IAMIdentityCenter

extension IAMIdentityCenterTestSuite {
@Suite("Portal listing", .serialized, .timeLimit(.minutes(1)))
struct PortalListingTests {

    private func makeService(keychain: InMemoryKeychainStore, portal: StubPortalRequesting) -> IdentityCenterService {
        IdentityCenterService(
            keychain: keychain,
            oidcClientProvider: makeStubOIDCProvider(StubOIDCRequesting()),
            portalClient: portal
        )
    }

    private func seedToken(keychain: InMemoryKeychainStore, region: String) async throws {
        try await keychain.writeRecord(
            StoredSSOToken(
                accessToken: "at",
                expiresAt: Date().addingTimeInterval(2 * 3600),
                refreshToken: "rt",
                issuedAt: Date().addingTimeInterval(-3600),
                region: region,
                sessionName: "s"
            ),
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: "s"
        )
    }

    @Test("accounts and roles are listed with the stored token in the session's region")
    func listsAccountsAndRolesWithTheStoredToken() async throws {
        let keychain = InMemoryKeychainStore()
        try await seedToken(keychain: keychain, region: "eu-west-1")
        let portal = StubPortalRequesting()
        await portal.setNextListAccountsResult(.success([
            PortalAccount(accountId: "111111111111", accountName: "Prod", emailAddress: "prod@example.com")
        ]))
        await portal.setNextListAccountRolesResult(.success([
            PortalRole(accountId: "111111111111", roleName: "Admin")
        ]))
        let service = makeService(keychain: keychain, portal: portal)

        let accounts = try await service.accounts(forSession: "s")
        #expect(accounts.map(\.accountName) == ["Prod"])
        #expect(await portal.lastListRegion == "eu-west-1")

        let roles = try await service.roles(forSession: "s", accountId: "111111111111")
        #expect(roles.map(\.roleName) == ["Admin"])
        #expect(await portal.listAccountsCallCount == 1)
        #expect(await portal.listAccountRolesCallCount == 1)
    }

    @Test("a signed-out session cannot list accounts")
    func signedOutSessionThrowsNotSignedIn() async throws {
        let portal = StubPortalRequesting()
        let service = makeService(keychain: InMemoryKeychainStore(), portal: portal)

        await #expect(throws: IAMIdentityCenterError.notSignedIn) {
            _ = try await service.accounts(forSession: "s")
        }
        #expect(await portal.listAccountsCallCount == 0)
    }
}
}
