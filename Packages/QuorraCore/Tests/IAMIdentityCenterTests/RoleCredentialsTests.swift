import Testing
import Foundation
@testable import IAMIdentityCenter

extension IAMIdentityCenterTestSuite {
@Suite("RoleCredentials", .serialized)
struct RoleCredentialsTests {
    @Test("Codable round-trip preserves the persisted Keychain record")
    func codableRoundTrip() throws {
        let original = makeCredentials()

        let data = try KeychainRecordCoder.encoder.encode(original)
        let decoded = try KeychainRecordCoder.decoder.decode(RoleCredentials.self, from: data)

        #expect(decoded == original)
    }

    @Test("Worst-case 12 KB session token survives the Keychain-store boundary")
    func worstCasePayloadRoundTrip() async throws {
        let bigToken = String(repeating: "X", count: 12_288)
        let creds = makeCredentials(sessionToken: bigToken)
        let keychain = InMemoryKeychainStore()

        try await keychain.writeRecord(
            creds,
            service: IdentityCenterService.ServiceConstants.roleCredsService,
            account: "big-token-session:123456789012:PowerUser"
        )
        let retrieved = try await keychain.readRecord(
            RoleCredentials.self,
            service: IdentityCenterService.ServiceConstants.roleCredsService,
            account: "big-token-session:123456789012:PowerUser"
        )

        #expect(retrieved == creds)
        #expect(retrieved.sessionToken.utf8.count == 12_288)
    }

    @Test("description redacts credential material but keeps provenance")
    func descriptionRedactsSecretsButKeepsProvenance() {
        let creds = makeCredentials(
            secretAccessKey: "super-secret-key-must-not-appear",
            sessionToken: "token-must-not-appear-in-description",
            sessionName: "prod-session"
        )

        let description = creds.description

        #expect(!description.contains("super-secret-key-must-not-appear"))
        #expect(!description.contains("token-must-not-appear-in-description"))
        #expect(description.contains("prod-session"))
        #expect(description.contains("123456789012"))
        #expect(description.contains("PowerUser"))
    }
}
}

private func makeCredentials(
    secretAccessKey: String = "stub-secret-key",
    sessionToken: String = "stub-session-token",
    sessionName: String = "big-token-session"
) -> RoleCredentials {
    RoleCredentials(
        accessKeyId: "ASIASTUB0000KEY",
        secretAccessKey: secretAccessKey,
        sessionToken: sessionToken,
        expiresAt: Date(timeIntervalSince1970: 1_700_000_000),
        accountId: "123456789012",
        roleName: "PowerUser",
        region: "eu-west-1",
        sessionName: sessionName,
        issuedAt: Date(timeIntervalSince1970: 1_699_996_400)
    )
}
