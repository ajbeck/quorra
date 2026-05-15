import Testing
import Foundation
@testable import IAMIdentityCenter

extension IAMIdentityCenterTestSuite {
@Suite("KeychainStore.enumerateAccounts", .serialized)
struct KeychainEnumerateTests {

    // Declare as `any KeychainStore` so calls go through the protocol (which has `async throws`),
    // giving correct `try await` semantics and eliminating spurious "no calls to throwing
    // functions" warnings from calling the non-throwing concrete implementations directly.
    private func makeKeychain() -> any KeychainStore {
        InMemoryKeychainStore()
    }

    // MARK: - InMemoryKeychainStore (test-seam coverage)

    @Test("enumerateAccounts returns all accounts for a service")
    func enumerateReturnsAllAccounts() async throws {
        let keychain = makeKeychain()
        let service = "dev.ajbeck.quorra.role-creds"

        let keys = [
            ("prod-session:123456789012:ReadOnly", Data("payload1".utf8)),
            ("prod-session:123456789012:Admin", Data("payload2".utf8)),
            ("dev-session:999999999999:Developer", Data("payload3".utf8)),
        ]

        for (account, data) in keys {
            try await keychain.write(data, service: service, account: account)
        }

        let accounts = try await keychain.enumerateAccounts(service: service)

        #expect(accounts.count == 3)
        #expect(accounts.contains("prod-session:123456789012:ReadOnly"))
        #expect(accounts.contains("prod-session:123456789012:Admin"))
        #expect(accounts.contains("dev-session:999999999999:Developer"))
    }

    @Test("enumerateAccounts returns empty when no rows for service")
    func enumerateReturnsEmptyWhenNone() async throws {
        let keychain = makeKeychain()
        let accounts = try await keychain.enumerateAccounts(service: "dev.ajbeck.quorra.role-creds")
        #expect(accounts.isEmpty)
    }

    @Test("enumerateAccounts isolates by service")
    func enumerateIsolatesByService() async throws {
        let keychain = makeKeychain()

        // Rows under two distinct services
        try await keychain.write(
            Data("token-payload".utf8),
            service: "dev.ajbeck.quorra.sso-token",
            account: "my-session"
        )
        try await keychain.write(
            Data("role-payload".utf8),
            service: "dev.ajbeck.quorra.role-creds",
            account: "my-session:123456789012:ReadOnly"
        )

        let ssoAccounts = try await keychain.enumerateAccounts(service: "dev.ajbeck.quorra.sso-token")
        let roleAccounts = try await keychain.enumerateAccounts(service: "dev.ajbeck.quorra.role-creds")

        #expect(ssoAccounts == ["my-session"])
        #expect(roleAccounts == ["my-session:123456789012:ReadOnly"])

        // Each service sees only its own accounts — no cross-contamination
        #expect(!ssoAccounts.contains("my-session:123456789012:ReadOnly"))
        #expect(!roleAccounts.contains("my-session"))
    }

    @Test("enumerateAccounts after delete does not include deleted account")
    func enumerateAfterDelete() async throws {
        let keychain = makeKeychain()
        let service = "dev.ajbeck.quorra.role-creds"

        try await keychain.write(Data("a".utf8), service: service, account: "sess:acct:role1")
        try await keychain.write(Data("b".utf8), service: service, account: "sess:acct:role2")

        // Delete one row
        try await keychain.delete(service: service, account: "sess:acct:role1")

        let accounts = try await keychain.enumerateAccounts(service: service)
        #expect(accounts == ["sess:acct:role2"])
    }

    @Test("enumerateAccounts prefix-filter mirrors D27 cascade pattern")
    func prefixFilterForSignOutCascade() async throws {
        // This test exercises the exact pattern the sign-out cascade uses (D27):
        // enumerate all accounts, filter by session prefix, delete matching rows.
        let keychain = makeKeychain()
        let service = "dev.ajbeck.quorra.role-creds"

        let sessionX = "session-x"
        let sessionY = "session-y"

        let pairs: [(String, Data)] = [
            ("\(sessionX):111111111111:ReadOnly", Data("rx".utf8)),
            ("\(sessionX):222222222222:Admin", Data("ax".utf8)),
            ("\(sessionY):111111111111:ReadOnly", Data("ry".utf8)),
        ]

        for (account, data) in pairs {
            try await keychain.write(data, service: service, account: account)
        }

        // Simulate D27: enumerate, filter by sessionX prefix, delete
        let all = try await keychain.enumerateAccounts(service: service)
        let toDelete = all.filter { $0.hasPrefix("\(sessionX):") }

        for account in toDelete {
            try await keychain.delete(service: service, account: account)
        }

        // Only sessionY's row should remain
        let remaining = try await keychain.enumerateAccounts(service: service)
        #expect(remaining.count == 1)
        #expect(remaining.contains("\(sessionY):111111111111:ReadOnly"))
        #expect(!remaining.contains(where: { $0.hasPrefix("\(sessionX):") }))
    }
}
}
