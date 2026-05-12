import Testing
import Foundation
@testable import IAMIdentityCenter

@Suite("OIDCClient", .serialized)
struct OIDCClientTests {
    // Helper to make a fresh makeSession() for each test
    func makeSession() -> URLSession {
        StubURLProtocol.makeSession()
    }

    // MARK: - RegisterClient

    @Test("registerClient - success")
    func registerClientSuccess() async throws {
        StubURLProtocol.reset()
        try StubURLProtocol.registerSuccess(
            urlSubstring: "/client/register",
            json: [
                "clientId": "test-client-id",
                "clientSecret": "test-secret",
                "clientIdIssuedAt": 1700000000,
                "clientSecretExpiresAt": 1707792000
            ]
        )

        let client = OIDCClient(region: "us-east-1", urlSession: makeSession())
        let result = try await client.registerClient(
            clientName: "Quorra",
            scopes: ["sso:account:access"]
        )

        #expect(result.clientId == "test-client-id")
        #expect(result.clientSecret == "test-secret")
        #expect(result.region == "us-east-1")
        #expect(result.scopes == ["sso:account:access"])
        #expect(result.issuedAt.timeIntervalSince1970 == 1700000000)
        #expect(result.secretExpiresAt.timeIntervalSince1970 == 1707792000)
    }

    @Test("registerClient - network failure")
    func registerClientNetworkFailure() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.registerNetworkFailure(urlSubstring: "/client/register")

        let client = OIDCClient(region: "us-east-1", urlSession: makeSession())
        await #expect(throws: IAMIdentityCenterError.self) {
            try await client.registerClient(clientName: "Quorra", scopes: [])
        }
    }

    @Test("registerClient - malformed response")
    func registerClientMalformedResponse() async throws {
        StubURLProtocol.reset()
        try StubURLProtocol.registerSuccess(
            urlSubstring: "/client/register",
            json: ["clientId": "only-one-field"]
        )

        let client = OIDCClient(region: "us-east-1", urlSession: makeSession())
        await #expect(performing: {
            try await client.registerClient(clientName: "Quorra", scopes: [])
        }, throws: { error in
            guard case .malformedResponse = error as? IAMIdentityCenterError else {
                return false
            }
            return true
        })
    }

    // MARK: - StartDeviceAuthorization

    @Test("startDeviceAuthorization - success")
    func startDeviceAuthorizationSuccess() async throws {
        StubURLProtocol.reset()
        try StubURLProtocol.registerSuccess(
            urlSubstring: "/device_authorization",
            json: [
                "deviceCode": "device-123",
                "userCode": "ABCD-1234",
                "verificationUri": "https://device.sso.aws.amazon.com/",
                "verificationUriComplete": "https://device.sso.aws.amazon.com/?user_code=ABCD-1234",
                "expiresIn": 600,
                "interval": 5
            ]
        )

        let client = OIDCClient(region: "us-east-1", urlSession: makeSession())
        let storedClient = StoredOIDCClient(
            clientId: "test-client",
            clientSecret: "test-secret",
            issuedAt: Date(),
            secretExpiresAt: Date().addingTimeInterval(86400 * 90),
            region: "us-east-1",
            scopes: []
        )

        let (deviceCode, verification) = try await client.startDeviceAuthorization(
            client: storedClient,
            startUrl: URL(string: "https://example.awsapps.com/start")!,
            sessionName: "test-makeSession()"
        )

        #expect(deviceCode == "device-123")
        #expect(verification.userCode == "ABCD-1234")
        #expect(verification.verificationUri.absoluteString == "https://device.sso.aws.amazon.com/")
        #expect(verification.verificationUriComplete.absoluteString.contains("user_code=ABCD-1234"))
        #expect(verification.interval == 5)
    }

    @Test("startDeviceAuthorization - interval defaults to 5")
    func startDeviceAuthorizationIntervalDefault() async throws {
        StubURLProtocol.reset()
        try StubURLProtocol.registerSuccess(
            urlSubstring: "/device_authorization",
            json: [
                "deviceCode": "device-123",
                "userCode": "ABCD-1234",
                "verificationUri": "https://device.sso.aws.amazon.com/",
                "verificationUriComplete": "https://device.sso.aws.amazon.com/?user_code=ABCD-1234",
                "expiresIn": 600
                // interval omitted
            ]
        )

        let client = OIDCClient(region: "us-east-1", urlSession: makeSession())
        let storedClient = StoredOIDCClient(
            clientId: "test-client",
            clientSecret: "test-secret",
            issuedAt: Date(),
            secretExpiresAt: Date().addingTimeInterval(86400 * 90),
            region: "us-east-1",
            scopes: []
        )

        let (_, verification) = try await client.startDeviceAuthorization(
            client: storedClient,
            startUrl: URL(string: "https://example.awsapps.com/start")!,
            sessionName: "test-makeSession()"
        )

        #expect(verification.interval == 5)
    }

    // MARK: - CreateToken

    @Test("createToken - success with refresh token")
    func createTokenSuccess() async throws {
        StubURLProtocol.reset()
        try StubURLProtocol.registerSuccess(
            urlSubstring: "/token",
            json: [
                "accessToken": "access-xyz",
                "tokenType": "Bearer",
                "expiresIn": 28800,
                "refreshToken": "refresh-abc"
            ]
        )

        let client = OIDCClient(region: "us-east-1", urlSession: makeSession())
        let storedClient = StoredOIDCClient(
            clientId: "test-client",
            clientSecret: "test-secret",
            issuedAt: Date(),
            secretExpiresAt: Date().addingTimeInterval(86400 * 90),
            region: "us-east-1",
            scopes: []
        )

        let token = try await client.createToken(
            client: storedClient,
            deviceCode: "device-123",
            sessionName: "test-makeSession()"
        )

        #expect(token.accessToken == "access-xyz")
        #expect(token.refreshToken == "refresh-abc")
        #expect(token.region == "us-east-1")
        #expect(token.sessionName == "test-makeSession()")
        // expiresAt is relative to now, verify it's in the future
        #expect(token.expiresAt > Date())
    }

    @Test("createToken - idToken is decoded but not stored")
    func createTokenIdTokenDiscarded() async throws {
        StubURLProtocol.reset()
        try StubURLProtocol.registerSuccess(
            urlSubstring: "/token",
            json: [
                "accessToken": "access-xyz",
                "tokenType": "Bearer",
                "expiresIn": 28800,
                "refreshToken": "refresh-abc",
                "idToken": "eyJ...jwt-data"
            ]
        )

        let client = OIDCClient(region: "us-east-1", urlSession: makeSession())
        let storedClient = StoredOIDCClient(
            clientId: "test-client",
            clientSecret: "test-secret",
            issuedAt: Date(),
            secretExpiresAt: Date().addingTimeInterval(86400 * 90),
            region: "us-east-1",
            scopes: []
        )

        let token = try await client.createToken(
            client: storedClient,
            deviceCode: "device-123",
            sessionName: "test-makeSession()"
        )

        // StoredSSOToken has no idToken field — verify we successfully decoded without storing it
        #expect(token.accessToken == "access-xyz")
        #expect(token.refreshToken == "refresh-abc")
    }

    // MARK: - OAuth Error Mapping

    @Test("createToken - authorization_pending")
    func createTokenAuthorizationPending() async throws {
        StubURLProtocol.reset()
        try StubURLProtocol.registerOAuthError(
            urlSubstring: "/token",
            error: "authorization_pending",
            errorDescription: "User has not yet authorized"
        )

        let client = OIDCClient(region: "us-east-1", urlSession: makeSession())
        let storedClient = StoredOIDCClient(
            clientId: "test-client",
            clientSecret: "test-secret",
            issuedAt: Date(),
            secretExpiresAt: Date().addingTimeInterval(86400 * 90),
            region: "us-east-1",
            scopes: []
        )

        await #expect(performing: {
            try await client.createToken(
                client: storedClient,
                deviceCode: "device-123",
                sessionName: "test"
            )
        }, throws: { error in
            guard case .authorizationPending = error as? IAMIdentityCenterError else {
                return false
            }
            return true
        })
    }

    @Test("createToken - slow_down")
    func createTokenSlowDown() async throws {
        StubURLProtocol.reset()
        try StubURLProtocol.registerOAuthError(
            urlSubstring: "/token",
            error: "slow_down"
        )

        let client = OIDCClient(region: "us-east-1", urlSession: makeSession())
        let storedClient = StoredOIDCClient(
            clientId: "test-client",
            clientSecret: "test-secret",
            issuedAt: Date(),
            secretExpiresAt: Date().addingTimeInterval(86400 * 90),
            region: "us-east-1",
            scopes: []
        )

        await #expect(performing: {
            try await client.createToken(
                client: storedClient,
                deviceCode: "device-123",
                sessionName: "test"
            )
        }, throws: { error in
            guard case .slowDown = error as? IAMIdentityCenterError else {
                return false
            }
            return true
        })
    }

    @Test("createToken - access_denied")
    func createTokenAccessDenied() async throws {
        StubURLProtocol.reset()
        try StubURLProtocol.registerOAuthError(
            urlSubstring: "/token",
            error: "access_denied"
        )

        let client = OIDCClient(region: "us-east-1", urlSession: makeSession())
        let storedClient = StoredOIDCClient(
            clientId: "test-client",
            clientSecret: "test-secret",
            issuedAt: Date(),
            secretExpiresAt: Date().addingTimeInterval(86400 * 90),
            region: "us-east-1",
            scopes: []
        )

        await #expect(performing: {
            try await client.createToken(
                client: storedClient,
                deviceCode: "device-123",
                sessionName: "test"
            )
        }, throws: { error in
            guard case .accessDenied = error as? IAMIdentityCenterError else {
                return false
            }
            return true
        })
    }

    @Test("createToken - expired_token")
    func createTokenExpiredToken() async throws {
        StubURLProtocol.reset()
        try StubURLProtocol.registerOAuthError(
            urlSubstring: "/token",
            error: "expired_token"
        )

        let client = OIDCClient(region: "us-east-1", urlSession: makeSession())
        let storedClient = StoredOIDCClient(
            clientId: "test-client",
            clientSecret: "test-secret",
            issuedAt: Date(),
            secretExpiresAt: Date().addingTimeInterval(86400 * 90),
            region: "us-east-1",
            scopes: []
        )

        await #expect(performing: {
            try await client.createToken(
                client: storedClient,
                deviceCode: "device-123",
                sessionName: "test"
            )
        }, throws: { error in
            guard case .expiredDeviceCode = error as? IAMIdentityCenterError else {
                return false
            }
            return true
        })
    }

    @Test("createToken - invalid_grant")
    func createTokenInvalidGrant() async throws {
        StubURLProtocol.reset()
        try StubURLProtocol.registerOAuthError(
            urlSubstring: "/token",
            error: "invalid_grant"
        )

        let client = OIDCClient(region: "us-east-1", urlSession: makeSession())
        let storedClient = StoredOIDCClient(
            clientId: "test-client",
            clientSecret: "test-secret",
            issuedAt: Date(),
            secretExpiresAt: Date().addingTimeInterval(86400 * 90),
            region: "us-east-1",
            scopes: []
        )

        await #expect(performing: {
            try await client.createToken(
                client: storedClient,
                deviceCode: "device-123",
                sessionName: "test"
            )
        }, throws: { error in
            guard case .invalidGrant = error as? IAMIdentityCenterError else {
                return false
            }
            return true
        })
    }

    @Test("createToken - invalid_client")
    func createTokenInvalidClient() async throws {
        StubURLProtocol.reset()
        try StubURLProtocol.registerOAuthError(
            urlSubstring: "/token",
            error: "invalid_client"
        )

        let client = OIDCClient(region: "us-east-1", urlSession: makeSession())
        let storedClient = StoredOIDCClient(
            clientId: "test-client",
            clientSecret: "test-secret",
            issuedAt: Date(),
            secretExpiresAt: Date().addingTimeInterval(86400 * 90),
            region: "us-east-1",
            scopes: []
        )

        await #expect(performing: {
            try await client.createToken(
                client: storedClient,
                deviceCode: "device-123",
                sessionName: "test"
            )
        }, throws: { error in
            guard case .invalidClient = error as? IAMIdentityCenterError else {
                return false
            }
            return true
        })
    }

    @Test("createToken - unknown error code")
    func createTokenUnknownError() async throws {
        StubURLProtocol.reset()
        try StubURLProtocol.registerOAuthError(
            urlSubstring: "/token",
            error: "unknown_future_error",
            errorDescription: "Some new error from AWS"
        )

        let client = OIDCClient(region: "us-east-1", urlSession: makeSession())
        let storedClient = StoredOIDCClient(
            clientId: "test-client",
            clientSecret: "test-secret",
            issuedAt: Date(),
            secretExpiresAt: Date().addingTimeInterval(86400 * 90),
            region: "us-east-1",
            scopes: []
        )

        await #expect(performing: {
            try await client.createToken(
                client: storedClient,
                deviceCode: "device-123",
                sessionName: "test"
            )
        }, throws: { error in
            guard case .awsError(let code, let description) = error as? IAMIdentityCenterError else {
                return false
            }
            return code == "unknown_future_error" && description == "Some new error from AWS"
        })
    }

    // MARK: - HTTP Status Errors

    @Test("createToken - 5xx with no body")
    func createToken5xxError() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.register5xxError(urlSubstring: "/token", statusCode: 503)

        let client = OIDCClient(region: "us-east-1", urlSession: makeSession())
        let storedClient = StoredOIDCClient(
            clientId: "test-client",
            clientSecret: "test-secret",
            issuedAt: Date(),
            secretExpiresAt: Date().addingTimeInterval(86400 * 90),
            region: "us-east-1",
            scopes: []
        )

        await #expect(performing: {
            try await client.createToken(
                client: storedClient,
                deviceCode: "device-123",
                sessionName: "test"
            )
        }, throws: { error in
            guard case .httpStatus(let status, _) = error as? IAMIdentityCenterError else {
                return false
            }
            return status == 503
        })
    }

    @Test("createToken - malformed JSON response")
    func createTokenMalformedJSON() async throws {
        StubURLProtocol.reset()
        let url = URL(string: "https://oidc.us-east-1.amazonaws.com/token")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        let malformedData = Data("not valid json".utf8)
        StubURLProtocol.register(
            urlSubstring: "/token",
            response: .success(malformedData, response)
        )

        let client = OIDCClient(region: "us-east-1", urlSession: makeSession())
        let storedClient = StoredOIDCClient(
            clientId: "test-client",
            clientSecret: "test-secret",
            issuedAt: Date(),
            secretExpiresAt: Date().addingTimeInterval(86400 * 90),
            region: "us-east-1",
            scopes: []
        )

        await #expect(performing: {
            try await client.createToken(
                client: storedClient,
                deviceCode: "device-123",
                sessionName: "test"
            )
        }, throws: { error in
            guard case .malformedResponse = error as? IAMIdentityCenterError else {
                return false
            }
            return true
        })
    }
}
