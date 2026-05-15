import Testing
import Foundation
@testable import IAMIdentityCenter

extension IAMIdentityCenterTestSuite {
@Suite("RoleCredentials", .serialized)
struct RoleCredentialsTests {

    // MARK: - Codable round-trip

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let original = RoleCredentials(
            accessKeyId: "ASIAIOSFODNN7EXAMPLE",
            secretAccessKey: "test-default-secret-key",
            sessionToken: "AQoDYXdzEJr//////////stub-session-token",
            expiresAt: Date(timeIntervalSince1970: 1700000000),
            accountId: "123456789012",
            roleName: "ReadOnly",
            region: "us-east-1",
            sessionName: "my-session",
            issuedAt: Date(timeIntervalSince1970: 1699996400)
        )

        let data = try KeychainRecordCoder.encoder.encode(original)
        let decoded = try KeychainRecordCoder.decoder.decode(RoleCredentials.self, from: data)

        #expect(decoded.accessKeyId == original.accessKeyId)
        #expect(decoded.secretAccessKey == original.secretAccessKey)
        #expect(decoded.sessionToken == original.sessionToken)
        #expect(decoded.expiresAt == original.expiresAt)
        #expect(decoded.accountId == original.accountId)
        #expect(decoded.roleName == original.roleName)
        #expect(decoded.region == original.region)
        #expect(decoded.sessionName == original.sessionName)
        #expect(decoded.issuedAt == original.issuedAt)
    }

    @Test("Encode-decode-encode produces Hashable-equal value")
    func codableRoundTripPreservesHashEquality() throws {
        // Verifies the round-trip produces an identical value at the Hashable level,
        // which is stronger than field-by-field equality and confirms no data loss.
        // JSONEncoder does not guarantee key ordering, so we compare the decoded value
        // (not re-encoded bytes) against the original.
        let creds = RoleCredentials(
            accessKeyId: "ASIASTUB0000KEY",
            secretAccessKey: "stub-secret-key",
            sessionToken: "short-token",
            expiresAt: Date(timeIntervalSince1970: 1700000000),
            accountId: "123456789012",
            roleName: "Developer",
            region: "us-west-2",
            sessionName: "dev-session",
            issuedAt: Date(timeIntervalSince1970: 1699996400)
        )

        let encoded = try KeychainRecordCoder.encoder.encode(creds)
        let decoded = try KeychainRecordCoder.decoder.decode(RoleCredentials.self, from: encoded)

        #expect(decoded == creds)
    }

    // MARK: - Worst-case 12 KB session token round-trip (D24 acceptance test)

    @Test("Worst-case 12 KB session token round-trips byte-equal through in-memory Keychain")
    func worstCasePayloadRoundTrip() async throws {
        // AWS STS session tokens can reach 12 KB. Verify the Keychain round-trip is byte-equal
        // at this worst-case size. Uses InMemoryKeychainStore (no Security-framework dependency
        // in test bundles per Apple TN3137).
        let bigToken = String(repeating: "X", count: 12_288) // 12 KB

        let creds = RoleCredentials(
            accessKeyId: "ASIASTUB0000KEY",
            secretAccessKey: "stub-secret-key",
            sessionToken: bigToken,
            expiresAt: Date(timeIntervalSince1970: 1700000000),
            accountId: "123456789012",
            roleName: "PowerUser",
            region: "eu-west-1",
            sessionName: "big-token-session",
            issuedAt: Date(timeIntervalSince1970: 1699996400)
        )

        let keychain = InMemoryKeychainStore()
        let service = "dev.ajbeck.quorra.role-creds"
        let account = "big-token-session:123456789012:PowerUser"

        try await keychain.writeRecord(creds, service: service, account: account)
        let retrieved = try await keychain.readRecord(RoleCredentials.self, service: service, account: account)

        // D24 acceptance test: byte-equal round-trip at worst-case size
        #expect(retrieved.sessionToken == bigToken)
        #expect(retrieved.sessionToken.utf8.count == 12_288)
        #expect(retrieved.accessKeyId == creds.accessKeyId)
        #expect(retrieved.secretAccessKey == creds.secretAccessKey)
        #expect(retrieved.expiresAt == creds.expiresAt)
        #expect(retrieved.accountId == creds.accountId)
        #expect(retrieved.roleName == creds.roleName)
        #expect(retrieved.region == creds.region)
        #expect(retrieved.sessionName == creds.sessionName)
        #expect(retrieved.issuedAt == creds.issuedAt)

        // Verify the retrieved value is Hashable-equal to the original (strongest round-trip check).
        // We don't compare JSON bytes directly since JSONEncoder has non-deterministic key ordering.
        #expect(retrieved == creds)
    }

    // MARK: - Redaction

    @Test("description never contains secretAccessKey")
    func descriptionRedactsSecretAccessKey() {
        let creds = RoleCredentials(
            accessKeyId: "ASIASTUB0000KEY",
            secretAccessKey: "super-secret-key-must-not-appear",
            sessionToken: "token-must-not-appear-in-description",
            expiresAt: Date(),
            accountId: "123456789012",
            roleName: "Developer",
            region: "us-east-1",
            sessionName: "my-session",
            issuedAt: Date()
        )

        let description = creds.description

        #expect(!description.contains("super-secret-key-must-not-appear"))
        #expect(!description.contains("token-must-not-appear-in-description"))
    }

    @Test("description contains non-secret provenance fields")
    func descriptionContainsProvenance() {
        let creds = RoleCredentials(
            accessKeyId: "ASIASTUB0000KEY",
            secretAccessKey: "secret",
            sessionToken: "token",
            expiresAt: Date(),
            accountId: "123456789012",
            roleName: "ReadOnly",
            region: "us-east-1",
            sessionName: "prod-session",
            issuedAt: Date()
        )

        let description = creds.description

        // Non-secret provenance should appear
        #expect(description.contains("prod-session"))
        #expect(description.contains("123456789012"))
        #expect(description.contains("ReadOnly"))
    }

    @Test("description does not contain any 16+ character secret-shaped substring")
    func descriptionRedactsLongSecrets() {
        let longSecret = String(repeating: "z", count: 40)
        let creds = RoleCredentials(
            accessKeyId: "ASIASTUB0000KEY",
            secretAccessKey: longSecret,
            sessionToken: longSecret,
            expiresAt: Date(),
            accountId: "123456789012",
            roleName: "PowerUser",
            region: "us-east-1",
            sessionName: "session",
            issuedAt: Date()
        )

        let description = creds.description

        #expect(!description.contains(longSecret))
        #expect(!description.contains(String(repeating: "z", count: 16)))
    }
}
}
