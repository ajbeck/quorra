import Testing
import Foundation
@testable import IAMIdentityCenter

@Suite("Keychain operations")
struct KeychainTests {

    /// Test-isolated access group using UUID to ensure hermeticity.
    func makeTestKeychain() -> Keychain {
        Keychain(accessGroup: "test.\(UUID().uuidString)")
    }

    @Test("Round-trip: write then read returns same data")
    func roundTripData() async throws {
        let keychain = makeTestKeychain()
        let data = "test-secret".data(using: .utf8)!

        try await keychain.write(data, service: "test.service", account: "test.account")
        let retrieved = try await keychain.read(service: "test.service", account: "test.account")

        #expect(retrieved == data)

        // Clean up
        try await keychain.delete(service: "test.service", account: "test.account")
    }

    @Test("Read missing item throws keychainItemMissing")
    func readMissingItem() async throws {
        let keychain = makeTestKeychain()

        do {
            _ = try await keychain.read(service: "missing.service", account: "missing.account")
            Issue.record("Expected keychainItemMissing to be thrown")
        } catch let error as IAMIdentityCenterError {
            if case .keychainItemMissing(let service, let account) = error {
                #expect(service == "missing.service")
                #expect(account == "missing.account")
            } else {
                Issue.record("Expected keychainItemMissing, got \(error)")
            }
        }
    }

    @Test("Update existing item replaces value")
    func updateExistingItem() async throws {
        let keychain = makeTestKeychain()
        let data1 = "first".data(using: .utf8)!
        let data2 = "second".data(using: .utf8)!

        defer {
            // Clean up in defer to ensure it runs even on test failure
            Task {
                try? await keychain.delete(service: "test.service", account: "test.account.update")
            }
        }

        try await keychain.write(data1, service: "test.service", account: "test.account.update")
        try await keychain.write(data2, service: "test.service", account: "test.account.update")
        let retrieved = try await keychain.read(service: "test.service", account: "test.account.update")

        #expect(retrieved == data2)
    }

    @Test("Delete removes item")
    func deleteItem() async throws {
        let keychain = makeTestKeychain()
        let data = "delete-me".data(using: .utf8)!

        try await keychain.write(data, service: "test.service", account: "test.account.delete")
        try await keychain.delete(service: "test.service", account: "test.account.delete")

        do {
            _ = try await keychain.read(service: "test.service", account: "test.account.delete")
            Issue.record("Expected item to be deleted")
        } catch is IAMIdentityCenterError {
            // Expected
        }
    }

    @Test("Delete non-existent item succeeds silently")
    func deleteNonExistentItem() async throws {
        let keychain = makeTestKeychain()

        // Should not throw
        try await keychain.delete(service: "never.existed", account: "never.existed")
    }

    @Test("Round-trip record: write then read StoredSSOToken")
    func roundTripRecord() async throws {
        let keychain = makeTestKeychain()
        let token = StoredSSOToken(
            accessToken: "test-access-token",
            expiresAt: Date(timeIntervalSince1970: 1704067200), // 2024-01-01 00:00:00 UTC
            refreshToken: "test-refresh-token",
            issuedAt: Date(timeIntervalSince1970: 1704063600),  // 1 hour earlier
            region: "us-east-1",
            sessionName: "test-session"
        )

        try await keychain.writeRecord(token, service: "test.sso-token", account: "test-session")
        let retrieved = try await keychain.readRecord(StoredSSOToken.self, service: "test.sso-token", account: "test-session")

        #expect(retrieved == token)

        // Clean up
        try await keychain.deleteRecord(service: "test.sso-token", account: "test-session")
    }

    @Test("Round-trip record: write then read StoredOIDCClient")
    func roundTripOIDCClient() async throws {
        let keychain = makeTestKeychain()
        let client = StoredOIDCClient(
            clientId: "test-client-id",
            clientSecret: "test-client-secret",
            issuedAt: Date(timeIntervalSince1970: 1704063600),
            secretExpiresAt: Date(timeIntervalSince1970: 1712000000), // ~90 days later
            region: "eu-west-1",
            scopes: ["sso:account:access"]
        )

        try await keychain.writeRecord(client, service: "test.oidc-client", account: "eu-west-1")
        let retrieved = try await keychain.readRecord(StoredOIDCClient.self, service: "test.oidc-client", account: "eu-west-1")

        #expect(retrieved == client)

        // Clean up
        try await keychain.deleteRecord(service: "test.oidc-client", account: "eu-west-1")
    }

    @Test("readRecord on missing item throws keychainItemMissing")
    func readRecordMissing() async throws {
        let keychain = makeTestKeychain()

        do {
            _ = try await keychain.readRecord(StoredSSOToken.self, service: "test.sso-token", account: "missing")
            Issue.record("Expected keychainItemMissing")
        } catch let error as IAMIdentityCenterError {
            if case .keychainItemMissing = error {
                // Expected
            } else {
                Issue.record("Expected keychainItemMissing, got \(error)")
            }
        }
    }

    @Test("readRecord with malformed data throws keychainMalformed")
    func readRecordMalformed() async throws {
        let keychain = makeTestKeychain()
        let badData = "not-json".data(using: .utf8)!

        try await keychain.write(badData, service: "test.sso-token", account: "malformed")

        do {
            _ = try await keychain.readRecord(StoredSSOToken.self, service: "test.sso-token", account: "malformed")
            Issue.record("Expected keychainMalformed")
        } catch let error as IAMIdentityCenterError {
            if case .keychainMalformed = error {
                // Expected
            } else {
                Issue.record("Expected keychainMalformed, got \(error)")
            }
        }

        // Clean up
        try await keychain.delete(service: "test.sso-token", account: "malformed")
    }

    @Test("deleteRecord removes logical record")
    func deleteRecord() async throws {
        let keychain = makeTestKeychain()
        let token = StoredSSOToken(
            accessToken: "delete-me",
            expiresAt: Date(),
            refreshToken: nil,
            issuedAt: Date(),
            region: "us-east-1",
            sessionName: "test"
        )

        try await keychain.writeRecord(token, service: "test.sso-token", account: "test")
        try await keychain.deleteRecord(service: "test.sso-token", account: "test")

        do {
            _ = try await keychain.readRecord(StoredSSOToken.self, service: "test.sso-token", account: "test")
            Issue.record("Expected item to be deleted")
        } catch is IAMIdentityCenterError {
            // Expected
        }
    }
}
