import Foundation

/// Protocol over the OIDC wire operations. Allows tests to inject a stub double instead
/// of configuring URLProtocol for tests that exercise actor behavior (not wire encoding).
///
/// `OIDCClient` conforms via retroactive extension; the service holds `any OIDCRequesting`.
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

extension OIDCClient: OIDCRequesting {}
