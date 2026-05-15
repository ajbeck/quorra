import Foundation

/// Short-lived STS role credentials minted from the IAM Identity Center Portal.
///
/// Stored in the Keychain per (session, account, role) tuple:
/// - `kSecAttrService`: `ServiceConstants.roleCredsService`
/// - `kSecAttrAccount`: `<sessionName>:<accountId>:<roleName>`
///
/// The struct carries AWS-supplied credential fields (D24) plus provenance metadata
/// needed for sign-out cascade, status queries, and debugging.
///
/// AWS API reference: `GetRoleCredentials` in the IAM Identity Center Portal API.
/// `expiration` comes over the wire as Unix milliseconds; we convert to `Date` on receipt.
public struct RoleCredentials: Sendable, Hashable, Codable {
    // MARK: - AWS-supplied fields

    /// Short-lived access key identifier (begins with "ASIA…").
    public let accessKeyId: String

    /// Secret access key corresponding to `accessKeyId`.
    public let secretAccessKey: String

    /// Session token required alongside `accessKeyId` and `secretAccessKey`.
    ///
    /// AWS STS session tokens may be up to 12 KB (documented maximum for the IAM Identity Center
    /// Portal `GetRoleCredentials` response). The Keychain item is JSON-encoded, making the
    /// total stored payload typically 800 B–2.2 KB, worst-case ~12.8 KB — well within Apple's
    /// practical "small chunks of data" guidance for generic-password items.
    public let sessionToken: String

    /// Absolute expiration time (converted from Unix-milliseconds wire format on receipt).
    public let expiresAt: Date

    // MARK: - Provenance (Quorra-added)

    /// AWS account ID this role credential is scoped to.
    public let accountId: String

    /// IAM Identity Center permission set name (role name).
    public let roleName: String

    /// AWS region the credential was minted in.
    public let region: String

    /// SSO session name (from `~/.aws/config` `[sso-session NAME]`) that authorized the mint.
    public let sessionName: String

    /// Wall-clock time this record was created by Quorra.
    public let issuedAt: Date

    public init(
        accessKeyId: String,
        secretAccessKey: String,
        sessionToken: String,
        expiresAt: Date,
        accountId: String,
        roleName: String,
        region: String,
        sessionName: String,
        issuedAt: Date
    ) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.expiresAt = expiresAt
        self.accountId = accountId
        self.roleName = roleName
        self.region = region
        self.sessionName = sessionName
        self.issuedAt = issuedAt
    }
}

// MARK: - Redaction

extension RoleCredentials: CustomStringConvertible {
    /// Returns a log-safe description that identifies the credential without revealing secret material.
    ///
    /// Mirrors `StoredSSOToken`'s pattern: secret fields are omitted entirely; non-secret
    /// provenance fields are surfaced so log lines remain actionable for debugging.
    public var description: String {
        "RoleCredentials(session: \(sessionName), account: \(accountId), role: \(roleName), expiresAt: \(expiresAt))"
    }
}
