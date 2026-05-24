import Testing
import Foundation
@testable import IAMIdentityCenter

@Suite("Redaction in CustomStringConvertible")
struct RedactionTests {
    @Test func ssoTokenDescriptionRedactsTokensButKeepsProvenance() {
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

    @Test func oidcClientDescriptionRedactsSecretButKeepsPublicFields() {
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
}
