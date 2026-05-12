import Foundation

/// URLSession-backed OIDC client for AWS IAM Identity Center device authorization flow.
///
/// Wraps three operations:
/// - `registerClient`: Registers a public OAuth 2.0 client
/// - `startDeviceAuthorization`: Begins the device-code grant flow
/// - `createToken`: Polls for the access token (device-code grant only in Phase 1)
///
/// Region-aware — all requests go to `oidc.<region>.amazonaws.com`.
public struct OIDCClient: Sendable {
    private let region: String
    private let baseURL: URL
    private let urlSession: URLSession

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Creates an OIDC client for the given region.
    ///
    /// - Parameters:
    ///   - region: AWS region (e.g. "us-east-1")
    ///   - urlSession: URLSession instance (injectable for testing)
    public init(region: String, urlSession: URLSession = .shared) {
        self.region = region
        // Region values reach this initializer from parsed `~/.aws/config` —
        // they're DNS-label shapes (e.g. "us-east-1"), so the `URL(string:)!` is
        // safe in practice. If a malformed region ever does slip through, the
        // crash is preferable to a silent wrong-host request.
        self.baseURL = URL(string: "https://oidc.\(region).amazonaws.com")!
        self.urlSession = urlSession
    }

    // MARK: - Operations

    /// Registers a public OAuth 2.0 client.
    ///
    /// - Parameters:
    ///   - clientName: Human-readable client name (e.g. "Quorra")
    ///   - scopes: Scopes to request (must include "sso:account:access" for refresh token issuance)
    /// - Returns: Stored OIDC client for reuse
    public func registerClient(
        clientName: String,
        scopes: [String]
    ) async throws -> StoredOIDCClient {
        let request = Wire.RegisterClientRequest(
            clientName: clientName,
            clientType: "public",
            scopes: scopes.isEmpty ? nil : scopes
        )

        let response: Wire.RegisterClientResponse = try await post(
            path: "/client/register",
            body: request
        )

        return StoredOIDCClient(
            clientId: response.clientId,
            clientSecret: response.clientSecret,
            issuedAt: Date(timeIntervalSince1970: TimeInterval(response.clientIdIssuedAt)),
            secretExpiresAt: Date(timeIntervalSince1970: TimeInterval(response.clientSecretExpiresAt)),
            region: region,
            scopes: scopes
        )
    }

    /// Starts the device authorization flow.
    ///
    /// - Parameters:
    ///   - client: Cached OIDC client registration
    ///   - startUrl: Identity Center start URL
    ///   - sessionName: SSO session name (for later token storage)
    /// - Returns: Tuple of (deviceCode for polling, verification info for the UI)
    public func startDeviceAuthorization(
        client: StoredOIDCClient,
        startUrl: URL,
        sessionName: String
    ) async throws -> (deviceCode: String, verification: DeviceVerification) {
        let request = Wire.StartDeviceAuthorizationRequest(
            clientId: client.clientId,
            clientSecret: client.clientSecret,
            startUrl: startUrl.absoluteString
        )

        let response: Wire.StartDeviceAuthorizationResponse = try await post(
            path: "/device_authorization",
            body: request
        )

        guard let verificationUri = URL(string: response.verificationUri),
              let verificationUriComplete = URL(string: response.verificationUriComplete) else {
            throw IAMIdentityCenterError.malformedResponse("Invalid verification URI in response")
        }

        let verification = DeviceVerification(
            userCode: response.userCode,
            verificationUri: verificationUri,
            verificationUriComplete: verificationUriComplete,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn)),
            interval: TimeInterval(response.interval ?? 5)
        )

        return (deviceCode: response.deviceCode, verification: verification)
    }

    /// Creates a token via device-code grant (polling operation).
    ///
    /// - Parameters:
    ///   - client: Cached OIDC client registration
    ///   - deviceCode: Device code from StartDeviceAuthorization
    ///   - sessionName: SSO session name (for token storage)
    /// - Returns: Stored SSO token
    public func createToken(
        client: StoredOIDCClient,
        deviceCode: String,
        sessionName: String
    ) async throws -> StoredSSOToken {
        let request = Wire.CreateTokenRequest(
            clientId: client.clientId,
            clientSecret: client.clientSecret,
            deviceCode: deviceCode,
            grantType: "urn:ietf:params:oauth:grant-type:device_code"
        )

        let response: Wire.CreateTokenResponse = try await post(
            path: "/token",
            body: request
        )

        return StoredSSOToken(
            accessToken: response.accessToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn)),
            refreshToken: response.refreshToken,
            issuedAt: Date(),
            region: region,
            sessionName: sessionName
        )
    }

    // MARK: - HTTP

    private func post<Request: Encodable, Response: Decodable>(
        path: String,
        body: Request
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let urlError as URLError {
            throw IAMIdentityCenterError.network(urlError)
        }

        if let error = HTTPErrorMapping.mapHTTPError(response: response, data: data) {
            throw error
        }

        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            throw IAMIdentityCenterError.malformedResponse("Failed to decode response: \(String(reflecting: error))")
        }
    }
}
