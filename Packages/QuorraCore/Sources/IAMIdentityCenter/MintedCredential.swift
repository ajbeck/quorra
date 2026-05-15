import Foundation

/// Wire-only mint result returned by `PortalRequesting.getRoleCredentials`.
///
/// Contains exactly the four fields the Portal API returns: the three credential strings and the
/// expiration timestamp (already converted from Unix-milliseconds wire format). Provenance fields
/// — `accountId`, `roleName`, `region`, `sessionName`, `issuedAt` — are NOT here; they are added
/// by the actor in a later chunk when it constructs the persisted `RoleCredentials` record.
///
/// Intentionally NOT `Codable` — this value is transient and never persisted.
public struct MintedCredential: Sendable, Hashable {
    /// Short-lived access key identifier (begins with "ASIA…").
    public let accessKeyId: String

    /// Secret access key corresponding to `accessKeyId`.
    public let secretAccessKey: String

    /// Session token required alongside `accessKeyId` and `secretAccessKey`.
    public let sessionToken: String

    /// Absolute expiration time (converted from Unix-milliseconds wire format on receipt).
    public let expiresAt: Date

    public init(
        accessKeyId: String,
        secretAccessKey: String,
        sessionToken: String,
        expiresAt: Date
    ) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.expiresAt = expiresAt
    }
}

// MARK: - Redaction

extension MintedCredential: CustomStringConvertible {
    /// Returns a log-safe description that identifies the credential without revealing secret material.
    ///
    /// Mirrors `RoleCredentials`'s pattern: secret fields are omitted entirely; non-secret
    /// fields are surfaced so log lines remain actionable for debugging.
    public var description: String {
        "MintedCredential(expiresAt: \(expiresAt))"
    }
}
