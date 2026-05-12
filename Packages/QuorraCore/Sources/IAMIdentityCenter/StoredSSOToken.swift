import Foundation

/// Persisted SSO access token from CreateToken.
///
/// Stored in the Keychain per session name. The access token is the bearer credential for SSO Portal calls;
/// the refresh token (when present) allows silent renewal without re-running the device flow.
public struct StoredSSOToken: Sendable, Hashable, Codable {
    /// Bearer access token.
    public let accessToken: String

    /// Absolute expiration time (computed from `expiresIn` at receive time).
    public let expiresAt: Date

    /// Refresh token (optional — only issued when registration included `sso:account:access` scope).
    public let refreshToken: String?

    /// When this token was issued.
    public let issuedAt: Date

    /// AWS region this token is valid in.
    public let region: String

    /// SSO session name (from `~/.aws/config` `[sso-session NAME]`).
    public let sessionName: String

    public init(
        accessToken: String,
        expiresAt: Date,
        refreshToken: String?,
        issuedAt: Date,
        region: String,
        sessionName: String
    ) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.refreshToken = refreshToken
        self.issuedAt = issuedAt
        self.region = region
        self.sessionName = sessionName
    }
}

// MARK: - Redaction

extension StoredSSOToken: CustomStringConvertible {
    public var description: String {
        "StoredSSOToken(session: \(sessionName), expiresAt: \(expiresAt), hasRefresh: \(refreshToken != nil))"
    }
}
