import Foundation
@testable import IAMIdentityCenter

/// Actor-based test double for `PortalRequesting`.
///
/// Replaces `StubURLProtocol` for tests that exercise actor behavior rather than wire encoding.
/// Wire-layer tests (`PortalClientTests`) keep using `StubURLProtocol` since they specifically
/// test HTTP encoding and error mapping.
///
/// Mirrors `StubOIDCRequesting`'s shape: actor isolation, per-verb canned results, call counters,
/// and an optional async block for the most-exercised verb to support in-flight sequencing tests.
///
/// Usage:
/// ```swift
/// let stub = StubPortalRequesting()
/// await stub.setNextGetRoleCredentialsResult(.success(creds))
/// let service = IdentityCenterService(keychain: keychain, portalClient: stub)
/// ```
actor StubPortalRequesting: PortalRequesting {

    // MARK: - Canned results (set per-test)

    var nextListAccountsResult: Result<[PortalAccount], Error> =
        .success([makeDefaultPortalAccount()])

    var nextListAccountRolesResult: Result<[PortalRole], Error> =
        .success([makeDefaultPortalRole()])

    var nextGetRoleCredentialsResult: Result<MintedCredential, Error> =
        .success(makeDefaultMintedCredential())

    /// Optional async block for `getRoleCredentials`. When set, overrides `nextGetRoleCredentialsResult`.
    /// Useful for tests that need the mint to block indefinitely (e.g. testing in-flight guards).
    var getRoleCredentialsBlock: (@Sendable () async throws -> MintedCredential)?

    // MARK: - Call counts

    private(set) var listAccountsCallCount = 0
    private(set) var listAccountRolesCallCount = 0
    private(set) var getRoleCredentialsCallCount = 0

    // MARK: - Configuration helpers

    func setNextListAccountsResult(_ result: Result<[PortalAccount], Error>) {
        nextListAccountsResult = result
    }

    func setNextListAccountRolesResult(_ result: Result<[PortalRole], Error>) {
        nextListAccountRolesResult = result
    }

    func setNextGetRoleCredentialsResult(_ result: Result<MintedCredential, Error>) {
        nextGetRoleCredentialsResult = result
        getRoleCredentialsBlock = nil
    }

    func setGetRoleCredentialsBlock(_ block: @escaping @Sendable () async throws -> MintedCredential) {
        getRoleCredentialsBlock = block
    }

    // MARK: - PortalRequesting

    func listAccounts(accessToken: String, region: String) async throws -> [PortalAccount] {
        listAccountsCallCount += 1
        return try nextListAccountsResult.get()
    }

    func listAccountRoles(
        accessToken: String,
        accountId: String,
        region: String
    ) async throws -> [PortalRole] {
        listAccountRolesCallCount += 1
        return try nextListAccountRolesResult.get()
    }

    func getRoleCredentials(
        accessToken: String,
        accountId: String,
        roleName: String,
        region: String
    ) async throws -> MintedCredential {
        getRoleCredentialsCallCount += 1
        if let block = getRoleCredentialsBlock {
            return try await block()
        }
        return try nextGetRoleCredentialsResult.get()
    }
}

// MARK: - Default values

func makeDefaultPortalAccount(
    accountId: String = "123456789012",
    accountName: String = "stub-account",
    emailAddress: String = "stub@example.com"
) -> PortalAccount {
    PortalAccount(accountId: accountId, accountName: accountName, emailAddress: emailAddress)
}

func makeDefaultPortalRole(
    accountId: String = "123456789012",
    roleName: String = "stub-role"
) -> PortalRole {
    PortalRole(accountId: accountId, roleName: roleName)
}

/// Wire-only mint result for stub usage. Used when the test only needs a `MintedCredential`
/// (e.g. actor tests that verify the stub path before provenance is attached).
func makeDefaultMintedCredential(
    accessKeyId: String = "ASIASTUB0000KEY",
    secretAccessKey: String = "stub-secret-access-key",
    sessionToken: String = "stub-session-token",
    expiresIn: TimeInterval = 3600
) -> MintedCredential {
    MintedCredential(
        accessKeyId: accessKeyId,
        secretAccessKey: secretAccessKey,
        sessionToken: sessionToken,
        expiresAt: Date().addingTimeInterval(expiresIn)
    )
}

/// Full provenance-bearing credential for stub usage. Used by actor tests that exercise
/// the construct-RoleCredentials path (a later chunk).
func makeDefaultRoleCredentials(
    accessKeyId: String = "ASIASTUB0000KEY",
    secretAccessKey: String = "stub-secret-access-key",
    sessionToken: String = "stub-session-token",
    expiresIn: TimeInterval = 3600,
    accountId: String = "123456789012",
    roleName: String = "stub-role",
    region: String = "us-east-1",
    sessionName: String = "s"
) -> RoleCredentials {
    RoleCredentials(
        accessKeyId: accessKeyId,
        secretAccessKey: secretAccessKey,
        sessionToken: sessionToken,
        expiresAt: Date().addingTimeInterval(expiresIn),
        accountId: accountId,
        roleName: roleName,
        region: region,
        sessionName: sessionName,
        issuedAt: Date()
    )
}
