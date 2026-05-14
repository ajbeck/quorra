import Testing
import Foundation
@testable import IAMIdentityCenter

extension IAMIdentityCenterTestSuite {
@Suite("OIDCClient refresh token", .serialized, .timeLimit(.minutes(1)))
struct OIDCClientRefreshTests {

    private func makeClient() -> OIDCClient {
        OIDCClient(region: "us-east-1", urlSession: StubURLProtocol.makeSession())
    }

    private func makeStoredClient(
        clientId: String = "test-client-id",
        clientSecret: String = "test-client-secret"
    ) -> StoredOIDCClient {
        StoredOIDCClient(
            clientId: clientId,
            clientSecret: clientSecret,
            issuedAt: Date(),
            secretExpiresAt: Date().addingTimeInterval(90 * 24 * 60 * 60),
            region: "us-east-1",
            scopes: ["sso:account:access"]
        )
    }

    // MARK: - Wire encoding
    //
    // A single test captures the full request shape: correct fields present, no deviceCode field.
    // `requestEncodesGrantType` and `requestOmitsDeviceCode` were duplicate stubs; merged here.

    @Test("RefreshTokenRequest wire encoding: grantType, refreshToken, clientId/Secret present; no deviceCode")
    func requestWireEncoding() async throws {
        defer { StubURLProtocol.reset() }
        // Capture as [String: Any] to check both string values and absence of deviceCode
        nonisolated(unsafe) var capturedBody: [String: Any] = [:]
        let lock = NSLock()

        StubURLProtocol.registerCustom(urlSubstring: "/token") { request in
            // URLSession may move httpBody into httpBodyStream; read both.
            let bodyData: Data?
            if let data = request.httpBody {
                bodyData = data
            } else if let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: 4096)
                    if read > 0 { data.append(buffer, count: read) }
                }
                stream.close()
                bodyData = data
            } else {
                bodyData = nil
            }
            if let data = bodyData,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                lock.withLock { capturedBody = json }
            }
            let data = try! JSONSerialization.data(withJSONObject: [
                "accessToken": "new-access-token",
                "tokenType": "Bearer",
                "expiresIn": 28800,
            ])
            let url = URL(string: "https://oidc.us-east-1.amazonaws.com/token")!
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            return (data, response)
        }

        let client = makeClient()
        _ = try await client.refreshToken(
            client: makeStoredClient(),
            refreshToken: "old-refresh-token",
            sessionName: "test-session"
        )

        let body = lock.withLock { capturedBody }
        #expect(body["grantType"] as? String == "refresh_token")
        #expect(body["refreshToken"] as? String == "old-refresh-token")
        #expect(body["clientId"] as? String == "test-client-id")
        #expect(body["clientSecret"] as? String == "test-client-secret")
        #expect(body["deviceCode"] == nil, "deviceCode must not appear in a refresh request")
    }

    // MARK: - Response decoding

    @Test("Successful refresh returns StoredSSOToken with new access token")
    func successfulRefreshReturnsToken() async throws {
        defer { StubURLProtocol.reset() }
        try StubURLProtocol.registerSuccess(urlSubstring: "/token", json: [
            "accessToken": "new-access-token",
            "tokenType": "Bearer",
            "expiresIn": 28800,
        ])

        let client = makeClient()
        let token = try await client.refreshToken(
            client: makeStoredClient(),
            refreshToken: "old-refresh-token",
            sessionName: "test-session"
        )

        #expect(token.accessToken == "new-access-token")
        #expect(token.sessionName == "test-session")
        #expect(token.region == "us-east-1")
    }

    // MARK: - Token rotation (D18)

    @Test("Token rotation: new refreshToken in response replaces old")
    func tokenRotationUsesNewRefreshToken() async throws {
        defer { StubURLProtocol.reset() }
        try StubURLProtocol.registerSuccess(urlSubstring: "/token", json: [
            "accessToken": "new-access-token",
            "tokenType": "Bearer",
            "expiresIn": 28800,
            "refreshToken": "rotated-refresh-token",
        ])

        let client = makeClient()
        let token = try await client.refreshToken(
            client: makeStoredClient(),
            refreshToken: "old-refresh-token",
            sessionName: "test-session"
        )

        // D18: AWS rotated the token — use the new one, discard old
        #expect(token.refreshToken == "rotated-refresh-token")
    }

    @Test("No rotation: response without refreshToken falls back to old refresh token")
    func noRotationKeepsOldRefreshToken() async throws {
        defer { StubURLProtocol.reset() }
        try StubURLProtocol.registerSuccess(urlSubstring: "/token", json: [
            "accessToken": "new-access-token",
            "tokenType": "Bearer",
            "expiresIn": 28800,
            // no refreshToken field
        ])

        let client = makeClient()
        let token = try await client.refreshToken(
            client: makeStoredClient(),
            refreshToken: "old-refresh-token",
            sessionName: "test-session"
        )

        // D18: AWS didn't rotate — keep old refresh token
        #expect(token.refreshToken == "old-refresh-token")
    }

    // MARK: - Error mapping (D14)

    @Test("invalid_grant maps to .refreshTokenRejected (terminal)")
    func invalidGrantMapsToRefreshTokenRejected() async throws {
        defer { StubURLProtocol.reset() }
        try StubURLProtocol.registerOAuthError(
            urlSubstring: "/token",
            statusCode: 400,
            error: "invalid_grant"
        )

        let client = makeClient()
        do {
            _ = try await client.refreshToken(
                client: makeStoredClient(),
                refreshToken: "bad-token",
                sessionName: "test-session"
            )
            Issue.record("Expected .refreshTokenRejected to be thrown")
        } catch IAMIdentityCenterError.refreshTokenRejected {
            // expected
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    @Test("invalid_client maps to .refreshClientInvalid (terminal)")
    func invalidClientMapsToRefreshClientInvalid() async throws {
        defer { StubURLProtocol.reset() }
        try StubURLProtocol.registerOAuthError(
            urlSubstring: "/token",
            statusCode: 400,
            error: "invalid_client"
        )

        let client = makeClient()
        do {
            _ = try await client.refreshToken(
                client: makeStoredClient(),
                refreshToken: "some-token",
                sessionName: "test-session"
            )
            Issue.record("Expected .refreshClientInvalid to be thrown")
        } catch IAMIdentityCenterError.refreshClientInvalid {
            // expected
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    @Test("Network error maps to .network (transient)")
    func networkErrorIsTransient() async throws {
        defer { StubURLProtocol.reset() }
        StubURLProtocol.registerNetworkFailure(urlSubstring: "/token")

        let client = makeClient()
        do {
            _ = try await client.refreshToken(
                client: makeStoredClient(),
                refreshToken: "some-token",
                sessionName: "test-session"
            )
            Issue.record("Expected .network error to be thrown")
        } catch IAMIdentityCenterError.network {
            // expected transient
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    @Test("5xx maps to .httpStatus (transient)")
    func serverErrorIsTransient() async throws {
        defer { StubURLProtocol.reset() }
        StubURLProtocol.register5xxError(urlSubstring: "/token")

        let client = makeClient()
        do {
            _ = try await client.refreshToken(
                client: makeStoredClient(),
                refreshToken: "some-token",
                sessionName: "test-session"
            )
            Issue.record("Expected .httpStatus error to be thrown")
        } catch IAMIdentityCenterError.httpStatus {
            // expected transient
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }
}
}
