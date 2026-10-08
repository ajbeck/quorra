import Foundation

/// Cached OIDC client registration from RegisterClient.
///
/// Persisted in the Keychain and reused until `secretExpiresAt` approaches (< 7 days remaining).
/// The client is regional and scoped; scope mismatches force re-registration.
public struct StoredOIDCClient: Sendable, Hashable, Codable {
    /// OIDC client ID.
    public let clientId: String

    /// OIDC client secret (bearer credential).
    public let clientSecret: String

    /// When the client ID was issued (Unix seconds).
    public let issuedAt: Date

    /// When the client secret expires (Unix seconds).
    public let secretExpiresAt: Date

    /// AWS region this client is registered in.
    public let region: String

    /// Scopes requested at registration time.
    public let scopes: [String]

    /// Grant types requested at registration time. `nil` for clients registered before
    /// browser sign-in, which AWS limited to the device code and refresh grants.
    public let grantTypes: [String]?

    /// The Identity Center issuer (start) URL the client was registered for, if any.
    public let issuerUrl: String?

    public init(
        clientId: String,
        clientSecret: String,
        issuedAt: Date,
        secretExpiresAt: Date,
        region: String,
        scopes: [String],
        grantTypes: [String]? = nil,
        issuerUrl: String? = nil
    ) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.issuedAt = issuedAt
        self.secretExpiresAt = secretExpiresAt
        self.region = region
        self.scopes = scopes
        self.grantTypes = grantTypes
        self.issuerUrl = issuerUrl
    }
}

// MARK: - Redaction

extension StoredOIDCClient: CustomStringConvertible {
    public var description: String {
        "StoredOIDCClient(clientId: \(clientId), region: \(region), secretExpiresAt: \(secretExpiresAt))"
    }
}
