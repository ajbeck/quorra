// SSOSession.swift — Codable struct for an AWS [sso-session NAME] section.
//
// Plan §5 (D10 lean surface), §13.2 task 4.
// Field names use camelCase; the default strategy maps them:
//
//   ssoStartUrl             ↔ sso_start_url
//   ssoRegion               ↔ sso_region
//   ssoRegistrationScopes   ↔ sso_registration_scopes
//
// `ssoRegistrationScopes` is a [String]? — the M06 decoder splits on "," and
// trims whitespace; the encoder joins with ", ". AWS docs show the value as a
// space-after-comma list, e.g. "sso:account:access, sso:role:read".
// Marshal spec §6.6 "delim" row; plan §13.2 task 4.
//
// No explicit CodingKeys needed — convertToSnakeCase handles all fields correctly.

/// A lean model of an AWS `[sso-session NAME]` section.
///
/// Decode with `AWSConfigINIDecoder.decode(_:from:section:)` passing the verbatim
/// section name `"sso-session NAME"`.
/// Plan §5 (D10); §13.2 task 4.
public struct SSOSession: Codable, Sendable, Hashable {
    /// Corresponds to the `sso_start_url` INI key.
    public var ssoStartUrl: String?
    /// Corresponds to the `sso_region` INI key.
    public var ssoRegion: String?
    /// Corresponds to the `sso_registration_scopes` INI key.
    /// Encoded as a comma-separated string (e.g. `"sso:account:access, sso:role:read"`).
    /// Marshal spec §6.6 "delim" row.
    public var ssoRegistrationScopes: [String]?

    public init(
        ssoStartUrl: String? = nil,
        ssoRegion: String? = nil,
        ssoRegistrationScopes: [String]? = nil
    ) {
        self.ssoStartUrl = ssoStartUrl
        self.ssoRegion = ssoRegion
        self.ssoRegistrationScopes = ssoRegistrationScopes
    }
}
