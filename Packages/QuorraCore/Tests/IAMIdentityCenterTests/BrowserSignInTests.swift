import CryptoKit
import Foundation
import Testing
@testable import IAMIdentityCenter

/// Browser sign-in: authorization code + PKCE with a loopback redirect (RFC 7636, RFC 8252).
/// The callback parsing and listener cases are ported from Duck Blind's `OAuthTests`.
extension IAMIdentityCenterTestSuite {
@Suite("Browser sign-in", .serialized, .timeLimit(.minutes(1)))
struct BrowserSignInTests {
    private let startUrl = URL(string: "https://example.awsapps.com/start")!

    // MARK: - Service round trip

    @Test("PKCE sign-in exchanges the callback code and binds the token to the session client")
    func pkceRoundTrip() async throws {
        let keychain = InMemoryKeychainStore()
        let stub = StubOIDCRequesting()
        await stub.setNextExchangeResult(.success(makeDefaultSSOToken(accessToken: "pkce-access", sessionName: "test-session")))
        let service = IdentityCenterService(keychain: keychain, oidcClientProvider: makeStubOIDCProvider(stub), sleeper: MockSleeper())
        let capture = VerificationCapture()

        let token = try await service.signIn(
            sessionName: "test-session",
            startUrl: startUrl,
            region: "us-east-1",
            scopes: ["sso:account:access"],
            useDeviceCode: false,
            verificationHandler: { verification in
                await capture.record(verification)
                try? await Self.completeCallback(authorizationURL: verification.verificationUriComplete, code: "synthetic-code")
            }
        )

        #expect(token.accessToken == "pkce-access")
        #expect(token.clientAccount == IdentityCenterService.sessionClientAccount(region: "us-east-1", startUrl: startUrl))
        #expect(await stub.exchangeCallCount == 1)
        #expect(await stub.startDeviceAuthorizationCallCount == 0)

        let verification = try #require(await capture.verification)
        #expect(verification.userCode == nil)
        let items = try #require(URLComponents(url: verification.verificationUriComplete, resolvingAgainstBaseURL: false)?.queryItems)
        let verifier = try #require(await stub.lastExchangeCodeVerifier)
        #expect(items.first { $0.name == "code_challenge" }?.value == OAuthPKCE.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))))

        let persisted = try await keychain.readRecord(StoredSSOToken.self, service: IdentityCenterService.ServiceConstants.ssoTokenService, account: "test-session")
        #expect(persisted.clientAccount == token.clientAccount)
    }

    @Test("Cancelling while the browser is open throws userCancelled")
    func cancelDuringBrowserWait() async throws {
        let stub = StubOIDCRequesting()
        let service = IdentityCenterService(keychain: InMemoryKeychainStore(), oidcClientProvider: makeStubOIDCProvider(stub), sleeper: MockSleeper())

        await #expect(throws: IAMIdentityCenterError.userCancelled) {
            try await service.signIn(
                sessionName: "test-session",
                startUrl: startUrl,
                region: "us-east-1",
                scopes: ["sso:account:access"],
                useDeviceCode: false,
                verificationHandler: { _ in
                    Task { await service.cancelSignIn(sessionName: "test-session") }
                }
            )
        }
        #expect(await stub.exchangeCallCount == 0)
    }

    @Test("A denied browser sign-in throws accessDenied")
    func deniedBrowserSignIn() async throws {
        let stub = StubOIDCRequesting()
        let service = IdentityCenterService(keychain: InMemoryKeychainStore(), oidcClientProvider: makeStubOIDCProvider(stub), sleeper: MockSleeper())

        await #expect(throws: IAMIdentityCenterError.accessDenied) {
            try await service.signIn(
                sessionName: "test-session",
                startUrl: startUrl,
                region: "us-east-1",
                scopes: ["sso:account:access"],
                useDeviceCode: false,
                verificationHandler: { verification in
                    try? await Self.completeCallback(authorizationURL: verification.verificationUriComplete, error: "access_denied")
                }
            )
        }
        #expect(await stub.exchangeCallCount == 0)
    }

    /// Plays the browser: reads `redirect_uri` and `state` from the authorize URL and calls back.
    private static func completeCallback(authorizationURL: URL, code: String? = nil, error: String? = nil) async throws {
        let items = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let redirect = try #require(items.first { $0.name == "redirect_uri" }?.value)
        let state = try #require(items.first { $0.name == "state" }?.value)
        var callback = try #require(URLComponents(string: redirect))
        callback.queryItems = [URLQueryItem(name: "state", value: state)] + [code.map { URLQueryItem(name: "code", value: $0) }, error.map { URLQueryItem(name: "error", value: $0) }].compactMap { $0 }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        _ = try await session.data(from: try #require(callback.url))
    }

    // MARK: - PKCE values

    @Test("PKCE matches the RFC 7636 vector and uses AWS's scopes parameter")
    func pkceMatchesRFC7636Vector() throws {
        let pkce = OAuthPKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "test-state")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let url = try pkce.authorizationURL(region: "eu-west-2", clientID: "id+&", redirectURI: URL(string: "http://127.0.0.1:4321/oauth/callback")!, scopes: ["sso:account:access"])
        #expect(url.host == "oidc.eu-west-2.amazonaws.com")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "scopes" }?.value == "sso:account:access")
        #expect(items.first { $0.name == "client_id" }?.value == "id+&")
        #expect(items.first { $0.name == "code_challenge_method" }?.value == "S256")
    }

    @Test("Fresh PKCE values are distinct and URL-safe")
    func freshPKCEValuesAreDistinctAndURLSafe() throws {
        let first = try OAuthPKCE.generate(), second = try OAuthPKCE.generate()
        #expect(first.verifier.count == 43)
        #expect(first.verifier != second.verifier)
        #expect(first.state != second.state)
        #expect(first.state != first.verifier)
        #expect(first.verifier.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil)
    }

    // MARK: - Callback parsing

    @Test("Callback preserves an encoded authorization code")
    func callbackPreservesEncodedAuthorizationCode() throws {
        #expect(try parse("/oauth/callback?state=expected&code=a%2Bb%26c") == "a+b&c")
    }

    @Test("Ambiguous or forged callbacks are rejected", arguments: [
        "/oauth/callback?state=wrong&code=code",
        "/oauth/callback?state=expected&state=expected&code=code",
        "/oauth/callback?state=expected&code=a&code=b",
        "/other?state=expected&code=code",
        "/oauth/callback?state=expected&code=",
        "/oauth/callback?state=expected&code=code#fragment",
        "/oauth/callback?state=expected&error=a&error=b&code=code",
        "/oauth/callback?state=expected&error=denied&code=code"
    ])
    func rejectsAmbiguousOrForgedCallback(path: String) {
        #expect(throws: BrowserSignInError.invalidCallback) { try parse(path) }
    }

    @Test("Wrong host, method, duplicate host and oversize header are rejected")
    func rejectsWrongHostMethodDuplicateHostAndOversizeHeader() {
        for request in [
            "GET /oauth/callback?state=expected&code=code HTTP/1.1\r\nHost: attacker.test\r\n\r\n",
            "POST /oauth/callback?state=expected&code=code HTTP/1.1\r\nHost: 127.0.0.1:4321\r\n\r\n",
            "GET /oauth/callback?state=expected&code=code HTTP/1.1\r\nHost: 127.0.0.1:4321\r\nHost: 127.0.0.1:4321\r\n\r\n",
            String(repeating: "x", count: 8193)
        ] {
            #expect(throws: BrowserSignInError.invalidCallback) {
                try OAuthCallbackRequest.code(from: Data(request.utf8), port: 4321, expectedState: "expected")
            }
        }
    }

    @Test("A denial needs a valid state")
    func denialRequiresValidatedState() {
        #expect(throws: BrowserSignInError.accessDenied) { try parse("/oauth/callback?state=expected&error=access_denied") }
        #expect(throws: BrowserSignInError.invalidCallback) { try parse("/oauth/callback?state=wrong&error=access_denied") }
    }

    private func parse(_ path: String) throws -> String {
        try OAuthCallbackRequest.code(from: Data("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:4321\r\n\r\n".utf8), port: 4321, expectedState: "expected")
    }

    // MARK: - Loopback listener

    @MainActor
    @Test("The listener ignores an invalid state and accepts a valid code")
    func listenerIgnoresInvalidStateAndAcceptsValidCode() async throws {
        let listener = LoopbackOAuthListener(expectedState: "synthetic-state")
        defer { listener.cancel() }
        let url = try await listener.start()
        #expect(url.host == "127.0.0.1")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, bad) = try await session.data(from: URL(string: url.absoluteString + "?state=wrong&code=wrong")!)
        #expect((bad as? HTTPURLResponse)?.statusCode == 400)
        let (body, good) = try await session.data(from: URL(string: url.absoluteString + "?state=synthetic-state&code=synthetic-code")!)
        #expect((good as? HTTPURLResponse)?.statusCode == 200)
        #expect(!String(decoding: body, as: UTF8.self).contains("synthetic-code"))
        #expect(try await listener.authorizationCode() == "synthetic-code")
    }

    @MainActor
    @Test("A cancelled listener does not hang waiting for the browser")
    func cancelledListenerDoesNotHang() async throws {
        let listener = LoopbackOAuthListener(expectedState: "state")
        _ = try await listener.start()
        listener.cancel()
        await #expect(throws: CancellationError.self) { try await listener.authorizationCode() }
    }
}
}
