import Foundation
import IAMIdentityCenter

/// The Quorra profile coordinates a database connection signs IAM tokens with.
nonisolated struct DatabaseRoleBinding: Sendable, Hashable {
    let sessionName: String
    let accountID: String
    let roleName: String
    /// The region Identity Center mints the profile's role credentials in.
    let region: String
}

/// Supplies role credentials for a binding. `IdentityCenterService.liveCredentials` mints inline
/// when the cached credentials are stale, so the proxy needs no refresh schedule of its own.
nonisolated protocol DatabaseRoleCredentialProviding: Sendable {
    func credentials(for binding: DatabaseRoleBinding) async throws -> RoleCredentials
}

nonisolated struct DatabaseLogin: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let username: String
    let password: String
    var description: String { "DatabaseLogin(redacted)" }
    var debugDescription: String { description }
}
