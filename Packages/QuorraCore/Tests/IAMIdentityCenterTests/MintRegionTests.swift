import Testing
import Foundation
@testable import IAMIdentityCenter

extension IAMIdentityCenterTestSuite {
@Suite("Mint region routing", .serialized, .timeLimit(.minutes(1)))
struct MintRegionTests {

    @Test("minting calls the Portal in the session's region and keeps the profile region on the credential")
    func mintUsesTheTokenRegionForThePortalHost() async throws {
        let keychain = InMemoryKeychainStore()
        try await keychain.writeRecord(
            StoredSSOToken(
                accessToken: "at",
                expiresAt: Date().addingTimeInterval(8 * 3600),
                refreshToken: "rt",
                issuedAt: Date(),
                region: "eu-west-1",
                sessionName: "s"
            ),
            service: IdentityCenterService.ServiceConstants.ssoTokenService,
            account: "s"
        )
        let portal = StubPortalRequesting()
        let service = IdentityCenterService(
            keychain: keychain,
            oidcClientProvider: makeStubOIDCProvider(StubOIDCRequesting()),
            portalClient: portal
        )

        let creds = try await service.liveCredentials(
            forSession: "s",
            accountId: "123456789012",
            roleName: "stub-role",
            region: "us-east-1"
        )

        #expect(await portal.lastMintRegion == "eu-west-1")
        #expect(creds.region == "us-east-1")
        #expect(creds.sessionName == "s")
    }
}
}
