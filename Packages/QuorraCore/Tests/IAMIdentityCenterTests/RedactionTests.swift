import Testing
import Foundation
@testable import IAMIdentityCenter

@Suite("Redaction in CustomStringConvertible")
struct RedactionTests {

    @Test("StoredSSOToken description does not contain access token")
    func ssoTokenRedactsAccessToken() {
        let token = StoredSSOToken(
            accessToken: "very-secret-access-token-should-not-appear",
            expiresAt: Date(),
            refreshToken: "very-secret-refresh-token-should-not-appear",
            issuedAt: Date(),
            region: "us-east-1",
            sessionName: "test-session"
        )

        let description = token.description

        #expect(!description.contains("very-secret-access-token"))
        #expect(!description.contains("very-secret-refresh-token"))
        #expect(description.contains("test-session"))
        #expect(description.contains("hasRefresh: true"))
    }

    @Test("StoredSSOToken description without refresh token shows hasRefresh: false")
    func ssoTokenRedactsRefreshTokenWhenNil() {
        let token = StoredSSOToken(
            accessToken: "access-token",
            expiresAt: Date(),
            refreshToken: nil,
            issuedAt: Date(),
            region: "us-east-1",
            sessionName: "test-session"
        )

        let description = token.description

        #expect(description.contains("hasRefresh: false"))
    }

    @Test("StoredOIDCClient description does not contain client secret")
    func oidcClientRedactsSecret() {
        let client = StoredOIDCClient(
            clientId: "public-client-id-okay-to-show",
            clientSecret: "very-secret-client-secret-should-not-appear",
            issuedAt: Date(),
            secretExpiresAt: Date(),
            region: "eu-west-1",
            scopes: ["sso:account:access"]
        )

        let description = client.description

        #expect(!description.contains("very-secret-client-secret"))
        #expect(description.contains("public-client-id-okay-to-show"))
        #expect(description.contains("eu-west-1"))
    }

    @Test("StoredSSOToken description does not contain any 16+ character secret-shaped substring")
    func ssoTokenRedactsLongSecrets() {
        let longSecret = String(repeating: "x", count: 32)
        let token = StoredSSOToken(
            accessToken: longSecret,
            expiresAt: Date(),
            refreshToken: longSecret,
            issuedAt: Date(),
            region: "us-east-1",
            sessionName: "test"
        )

        let description = token.description

        // Should not contain any 16+ character runs that look like secrets
        #expect(!description.contains(longSecret))
        #expect(!description.contains(String(repeating: "x", count: 16)))
    }

    @Test("StoredOIDCClient description does not contain any 16+ character secret-shaped substring")
    func oidcClientRedactsLongSecrets() {
        let longSecret = String(repeating: "y", count: 40)
        let client = StoredOIDCClient(
            clientId: "client-id",
            clientSecret: longSecret,
            issuedAt: Date(),
            secretExpiresAt: Date(),
            region: "us-east-1",
            scopes: []
        )

        let description = client.description

        #expect(!description.contains(longSecret))
        #expect(!description.contains(String(repeating: "y", count: 16)))
    }
}
