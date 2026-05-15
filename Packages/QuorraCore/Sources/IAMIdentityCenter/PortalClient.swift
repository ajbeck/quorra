import Foundation

/// URLSession-backed IAM Identity Center Portal client.
///
/// Wraps three GET operations against `portal.sso.<region>.amazonaws.com`:
/// - `listAccounts` — pages all accounts the user is assigned to (pagination handled internally)
/// - `listAccountRoles` — pages all roles for a given account (pagination handled internally)
/// - `getRoleCredentials` — mints short-lived STS credentials for an (account, role) pair
///
/// All three operations authenticate with the SSO access token via the `x-amz-sso_bearer_token`
/// header (Portal API reference). Error responses use the AWS REST-JSON 1.1 error envelope
/// (`__type` + `message`), not the OAuth `error`/`error_description` shape used by the OIDC
/// endpoints — see `Wire.AWSServiceErrorResponse` and `HTTPErrorMapping.mapPortalError`.
///
/// Region-aware — all requests go to `portal.sso.<region>.amazonaws.com`.
public struct PortalClient: Sendable {
    private let urlSession: URLSession

    private static let decoder = JSONDecoder()

    /// Creates a Portal client.
    ///
    /// - Parameter urlSession: URLSession instance (injectable for testing).
    ///   Uses `.shared` by default.
    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    // MARK: - PortalRequesting

    /// Returns all accounts the authenticated user is assigned to.
    ///
    /// Pages through all `nextToken` pages internally; returns a flat array.
    public func listAccounts(
        accessToken: String,
        region: String
    ) async throws -> [PortalAccount] {
        let baseURL = portalBaseURL(region: region)
        var accounts: [PortalAccount] = []
        var nextToken: String? = nil

        repeat {
            var components = URLComponents(url: baseURL.appending(path: "/assignment/accounts"), resolvingAgainstBaseURL: false)!
            var queryItems: [URLQueryItem] = []
            if let token = nextToken {
                queryItems.append(URLQueryItem(name: "next_token", value: token))
            }
            if !queryItems.isEmpty {
                components.queryItems = queryItems
            }

            let response: Wire.ListAccountsResponse = try await get(
                url: components.url!,
                accessToken: accessToken
            )

            let page = response.accountList.map {
                PortalAccount(
                    accountId: $0.accountId,
                    accountName: $0.accountName,
                    emailAddress: $0.emailAddress
                )
            }
            accounts.append(contentsOf: page)
            nextToken = response.nextToken
        } while nextToken != nil

        return accounts
    }

    /// Returns all roles the authenticated user can assume in the given account.
    ///
    /// Pages through all `nextToken` pages internally; returns a flat array.
    public func listAccountRoles(
        accessToken: String,
        accountId: String,
        region: String
    ) async throws -> [PortalRole] {
        let baseURL = portalBaseURL(region: region)
        var roles: [PortalRole] = []
        var nextToken: String? = nil

        repeat {
            var components = URLComponents(url: baseURL.appending(path: "/assignment/roles"), resolvingAgainstBaseURL: false)!
            var queryItems: [URLQueryItem] = [URLQueryItem(name: "account_id", value: accountId)]
            if let token = nextToken {
                queryItems.append(URLQueryItem(name: "next_token", value: token))
            }
            components.queryItems = queryItems

            let response: Wire.ListAccountRolesResponse = try await get(
                url: components.url!,
                accessToken: accessToken
            )

            let page = response.roleList.map {
                PortalRole(accountId: $0.accountId, roleName: $0.roleName)
            }
            roles.append(contentsOf: page)
            nextToken = response.nextToken
        } while nextToken != nil

        return roles
    }

    /// Mints short-lived STS credentials for the given (account, role) pair.
    ///
    /// Returns a `MintedCredential` containing only the wire-response fields. Provenance
    /// (`accountId`, `roleName`, `region`, `sessionName`, `issuedAt`) is attached by the actor
    /// in a later chunk when it constructs the persisted `RoleCredentials` record.
    ///
    /// `expiration` in the response is Unix **milliseconds**; we divide by 1000 to get
    /// `TimeInterval` for `Date(timeIntervalSince1970:)` — per the Portal API reference docs.
    public func getRoleCredentials(
        accessToken: String,
        accountId: String,
        roleName: String,
        region: String
    ) async throws -> MintedCredential {
        let baseURL = portalBaseURL(region: region)
        var components = URLComponents(url: baseURL.appending(path: "/federation/credentials"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "account_id", value: accountId),
            URLQueryItem(name: "role_name", value: roleName),
        ]

        let response: Wire.GetRoleCredentialsResponse = try await get(
            url: components.url!,
            accessToken: accessToken
        )

        let creds = response.roleCredentials
        return MintedCredential(
            accessKeyId: creds.accessKeyId,
            secretAccessKey: creds.secretAccessKey,
            sessionToken: creds.sessionToken,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(creds.expiration) / 1000.0)
        )
    }

    // MARK: - HTTP

    internal func get<Response: Decodable>(
        url: URL,
        accessToken: String
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(accessToken, forHTTPHeaderField: "x-amz-sso_bearer_token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let urlError as URLError {
            throw IAMIdentityCenterError.network(urlError)
        }

        if let error = HTTPErrorMapping.mapPortalHTTPError(response: response, data: data) {
            throw error
        }

        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            throw IAMIdentityCenterError.malformedResponse("Failed to decode Portal response: \(String(reflecting: error))")
        }
    }

    // MARK: - Helpers

    /// Constructs the Portal base URL for a given region.
    ///
    /// Region values come from parsed `~/.aws/config` — they are DNS-label shaped
    /// (e.g. "us-east-1"), so the `URL(string:)!` force-unwrap is safe in practice.
    /// If a malformed region slips through, crashing here is preferable to a silent
    /// wrong-host request. Mirrors `OIDCClient`'s init convention.
    private func portalBaseURL(region: String) -> URL {
        URL(string: "https://portal.sso.\(region).amazonaws.com")!
    }
}
