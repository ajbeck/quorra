import Foundation
import IAMIdentityCenter

/// The Quorra profile coordinates a database connection signs IAM tokens with.
public nonisolated struct DatabaseRoleBinding: Sendable, Hashable {
    public let sessionName: String
    public let accountID: String
    public let roleName: String
    /// The region Identity Center mints the profile's role credentials in.
    public let region: String

    public init(sessionName: String, accountID: String, roleName: String, region: String) {
        self.sessionName = sessionName
        self.accountID = accountID
        self.roleName = roleName
        self.region = region
    }
}

/// Supplies role credentials for a binding. `IdentityCenterService.liveCredentials` mints inline
/// when the cached credentials are stale, so the proxy needs no refresh schedule of its own.
public nonisolated protocol DatabaseRoleCredentialProviding: Sendable {
    func credentials(for binding: DatabaseRoleBinding) async throws -> RoleCredentials
}

public nonisolated struct DatabaseLogin: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let username: String
    public let password: String
    public var description: String { "DatabaseLogin(redacted)" }
    public var debugDescription: String { description }

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}
