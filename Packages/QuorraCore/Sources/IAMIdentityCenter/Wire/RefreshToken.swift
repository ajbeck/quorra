import Foundation

extension Wire {
    /// POST /token request body for the refresh-token grant (RFC 6749 §6).
    ///
    /// Intentionally separate from `CreateTokenRequest` — the two grant types share the same
    /// endpoint but have different required fields. Keeping them as distinct types makes
    /// illegal states (both `deviceCode` and `refreshToken` set, or neither) impossible at
    /// the type level (D15).
    ///
    /// `grantType` is always `"refresh_token"`.
    internal struct RefreshTokenRequest: Codable, Sendable {
        let clientId: String
        let clientSecret: String
        let refreshToken: String
        let grantType: String
    }

    // Response re-uses CreateTokenResponse — same JSON shape, refreshToken may or may not be
    // present (AWS may or may not rotate the refresh token per RFC 6749 §6 + §10.4, D18).
}
