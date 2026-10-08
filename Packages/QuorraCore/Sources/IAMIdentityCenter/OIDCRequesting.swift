import Foundation

/// Protocol over the OIDC wire operations. The production implementation is `SDKOIDCClient`
/// (backed by `AWSSSOOIDC.SSOOIDCClient`), vended per-region by `OIDCClientProviding`; tests
/// inject `StubOIDCRequesting` through the same seam to exercise actor behavior without the wire.
///
/// Apple's documented pattern: *"Replace complex dependencies with stubs… Adopting
/// dependency injection and protocol-oriented programming."* — Apple Testing documentation.
public protocol OIDCRequesting: Sendable {
    /// Registers a client for one Identity Center instance that can use the authorization code
    /// (PKCE), device code and refresh token grants, so either sign-in mints tokens it can refresh.
    func registerSessionClient(
        clientName: String,
        scopes: [String],
        issuerUrl: URL,
        redirectUri: String
    ) async throws -> StoredOIDCClient

    /// Exchanges an authorization code from the browser callback for a token.
    func exchangeAuthorizationCode(
        client: StoredOIDCClient,
        code: String,
        codeVerifier: String,
        redirectUri: String,
        sessionName: String
    ) async throws -> StoredSSOToken

    func startDeviceAuthorization(
        client: StoredOIDCClient,
        startUrl: URL,
        sessionName: String
    ) async throws -> (deviceCode: String, verification: DeviceVerification)

    func createToken(
        client: StoredOIDCClient,
        deviceCode: String,
        sessionName: String
    ) async throws -> StoredSSOToken

    func refreshToken(
        client: StoredOIDCClient,
        refreshToken: String,
        sessionName: String
    ) async throws -> StoredSSOToken
}
