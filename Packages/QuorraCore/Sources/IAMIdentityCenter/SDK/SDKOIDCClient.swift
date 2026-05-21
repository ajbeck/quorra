import Foundation
import AWSSSOOIDC

/// `OIDCRequesting` implementation backed by `AWSSSOOIDC.SSOOIDCClient`.
///
/// **Region-bound at init.** The SDK client's config carries the region, so this adapter
/// is constructed once per region and lives behind `SDKOIDCClientProvider`. Translates
/// Quorra domain types ↔ SDK Input/Output. Errors route through `SDKErrorMapping`.
///
/// **Sendability.** `SSOOIDCClient` is a class with internal state (signer, retry strategy,
/// HTTP client) but is documented thread-safe. We do not mutate after init, so the
/// adapter is `@unchecked Sendable`.
public final class SDKOIDCClient: OIDCRequesting, @unchecked Sendable {
    private let region: String
    private let client: SSOOIDCClient

    public init(region: String) async throws {
        self.region = region
        let config = try await SSOOIDCClient.SSOOIDCClientConfiguration(region: region)
        self.client = SSOOIDCClient(config: config)
    }

    /// Routes a thrown SDK error through the containment boundary.
    /// One line in every catch block keeps the boundary visible at every call site.
    private func mapped(_ error: any Error) -> IAMIdentityCenterError {
        let (typeName, message) = SDKErrorMapping.extract(from: error)
        return SDKErrorMapping.mapOIDC(typeName: typeName, message: message)
    }

    public func registerClient(
        clientName: String,
        scopes: [String]
    ) async throws -> StoredOIDCClient {
        let input = RegisterClientInput(
            clientName: clientName,
            clientType: "public",
            scopes: scopes.isEmpty ? nil : scopes
        )
        let output: RegisterClientOutput
        do { output = try await client.registerClient(input: input) }
        catch { throw mapped(error) }

        guard let clientId = output.clientId,
              let clientSecret = output.clientSecret
        else { throw IAMIdentityCenterError.malformedResponse("RegisterClient missing required fields") }

        return StoredOIDCClient(
            clientId: clientId,
            clientSecret: clientSecret,
            issuedAt: Date(timeIntervalSince1970: TimeInterval(output.clientIdIssuedAt)),
            secretExpiresAt: Date(timeIntervalSince1970: TimeInterval(output.clientSecretExpiresAt)),
            region: region,
            scopes: scopes
        )
    }

    public func startDeviceAuthorization(
        client storedClient: StoredOIDCClient,
        startUrl: URL,
        sessionName: String
    ) async throws -> (deviceCode: String, verification: DeviceVerification) {
        let input = StartDeviceAuthorizationInput(
            clientId: storedClient.clientId,
            clientSecret: storedClient.clientSecret,
            startUrl: startUrl.absoluteString
        )
        let output: StartDeviceAuthorizationOutput
        do { output = try await client.startDeviceAuthorization(input: input) }
        catch { throw mapped(error) }

        guard let deviceCode = output.deviceCode,
              let userCode = output.userCode,
              let vUri = output.verificationUri.flatMap(URL.init(string:)),
              let vUriComplete = output.verificationUriComplete.flatMap(URL.init(string:))
        else { throw IAMIdentityCenterError.malformedResponse("StartDeviceAuthorization missing required fields") }

        let verification = DeviceVerification(
            userCode: userCode,
            verificationUri: vUri,
            verificationUriComplete: vUriComplete,
            expiresAt: Date().addingTimeInterval(TimeInterval(output.expiresIn)),
            interval: TimeInterval(output.interval == 0 ? 5 : output.interval)
        )
        return (deviceCode, verification)
    }

    public func createToken(
        client storedClient: StoredOIDCClient,
        deviceCode: String,
        sessionName: String
    ) async throws -> StoredSSOToken {
        let input = CreateTokenInput(
            clientId: storedClient.clientId,
            clientSecret: storedClient.clientSecret,
            deviceCode: deviceCode,
            grantType: "urn:ietf:params:oauth:grant-type:device_code"
        )
        let output: CreateTokenOutput
        do { output = try await client.createToken(input: input) }
        catch { throw mapped(error) }

        return try makeToken(from: output, fallbackRefreshToken: nil, sessionName: sessionName)
    }

    public func refreshToken(
        client storedClient: StoredOIDCClient,
        refreshToken: String,
        sessionName: String
    ) async throws -> StoredSSOToken {
        let input = CreateTokenInput(
            clientId: storedClient.clientId,
            clientSecret: storedClient.clientSecret,
            grantType: "refresh_token",
            refreshToken: refreshToken
        )
        let output: CreateTokenOutput
        do {
            output = try await client.createToken(input: input)
        } catch {
            // Re-map terminal OAuth codes to refresh-specific cases (D14), matching the
            // hand-rolled OIDCClient: the actor's refresh-failure path only treats
            // .refreshTokenRejected / .refreshClientInvalid as terminal (clears the refresh
            // token / forces re-registration). Without this remap a rejected refresh would
            // be mishandled as transient and the dead refresh token would never be cleared.
            switch mapped(error) {
            case .invalidGrant:  throw IAMIdentityCenterError.refreshTokenRejected
            case .invalidClient: throw IAMIdentityCenterError.refreshClientInvalid
            case let other:      throw other
            }
        }

        // D18 / RFC 6749 §10.4: use the new refresh token when AWS rotates it; otherwise keep
        // the existing one. AWS frequently omits the refresh token on a refresh response when
        // it isn't rotating — nil-ing it out here would force an unnecessary re-sign-in on the
        // next cycle. Never preserve both: the old token is invalid only once AWS rotates.
        return try makeToken(from: output, fallbackRefreshToken: refreshToken, sessionName: sessionName)
    }

    private func makeToken(
        from output: CreateTokenOutput,
        fallbackRefreshToken: String?,
        sessionName: String
    ) throws -> StoredSSOToken {
        guard let accessToken = output.accessToken
        else { throw IAMIdentityCenterError.malformedResponse("CreateToken missing accessToken") }

        return StoredSSOToken(
            accessToken: accessToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(output.expiresIn)),
            refreshToken: output.refreshToken ?? fallbackRefreshToken,
            issuedAt: Date(),
            region: region,
            sessionName: sessionName
        )
    }
}
