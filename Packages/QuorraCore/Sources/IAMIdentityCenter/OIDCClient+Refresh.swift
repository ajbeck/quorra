import Foundation

extension OIDCClient {
    // MARK: - Token refresh (D15, D18)

    /// Exchanges a refresh token for a new access token via RFC 6749 §6.
    ///
    /// Hits the same `/token` endpoint as `createToken` but sends `grantType = "refresh_token"`
    /// and `refreshToken` instead of `deviceCode`. Error mapping is different from `createToken`:
    /// - `invalid_grant` → `.refreshTokenRejected` (terminal — clear refresh token, keep access token)
    /// - `invalid_client` → `.refreshClientInvalid` (terminal — client must re-register on next sign-in)
    /// - URLError → `.network` (transient)
    /// - 5xx → `.httpStatus` (transient)
    ///
    /// Token rotation (D18, RFC 6749 §10.4): the returned `StoredSSOToken` uses
    /// `response.refreshToken ?? oldRefreshToken` — replace when AWS rotates, keep old when
    /// AWS doesn't. Never preserve the old refresh token as a fallback after rotation.
    ///
    /// - Parameters:
    ///   - client: The registered OIDC client (provides `clientId` + `clientSecret`)
    ///   - refreshToken: The current refresh token to exchange
    ///   - sessionName: SSO session name (for constructing the returned token)
    /// - Returns: New `StoredSSOToken` with updated `accessToken`, `expiresAt`, and `refreshToken`
    /// - Throws: `.refreshTokenRejected`, `.refreshClientInvalid` (terminal);
    ///   `.network`, `.httpStatus` (transient); `.malformedResponse` on decode failure
    public func refreshToken(
        client: StoredOIDCClient,
        refreshToken: String,
        sessionName: String
    ) async throws -> StoredSSOToken {
        let requestBody = Wire.RefreshTokenRequest(
            clientId: client.clientId,
            clientSecret: client.clientSecret,
            refreshToken: refreshToken,
            grantType: "refresh_token"
        )

        let response: Wire.CreateTokenResponse
        do {
            response = try await post(path: "/token", body: requestBody)
        } catch let error as IAMIdentityCenterError {
            // Re-map the terminal OAuth error codes to refresh-specific cases (D14)
            switch error {
            case .invalidGrant:
                throw IAMIdentityCenterError.refreshTokenRejected
            case .invalidClient:
                throw IAMIdentityCenterError.refreshClientInvalid
            default:
                throw error
            }
        }

        // D18 — RFC 6749 §6 + §10.4: use new refresh_token if AWS rotated it; otherwise
        // keep the old one. Never preserve both — old one is invalid after rotation.
        let newRefreshToken = response.refreshToken ?? refreshToken

        return StoredSSOToken(
            accessToken: response.accessToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn)),
            refreshToken: newRefreshToken,
            issuedAt: Date(),
            region: client.region,
            sessionName: sessionName
        )
    }
}
