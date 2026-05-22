import Foundation

/// Protocol over the OIDC wire operations. The production implementation is `SDKOIDCClient`
/// (backed by `AWSSSOOIDC.SSOOIDCClient`), vended per-region by `OIDCClientProviding`; tests
/// inject `StubOIDCRequesting` through the same seam to exercise actor behavior without the wire.
///
/// Apple's documented pattern: *"Replace complex dependencies with stubs… Adopting
/// dependency injection and protocol-oriented programming."* — Apple Testing documentation.
public protocol OIDCRequesting: Sendable {
    func registerClient(
        clientName: String,
        scopes: [String]
    ) async throws -> StoredOIDCClient

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
