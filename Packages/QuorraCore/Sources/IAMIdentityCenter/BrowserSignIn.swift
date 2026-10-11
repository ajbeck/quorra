import CryptoKit
import Foundation
import LoopbackCallback
import Security

/// OAuth 2.0 grant type identifiers used with IAM Identity Center OIDC.
enum OAuthGrant {
    static let authorizationCode = "authorization_code"
    static let deviceCode = "urn:ietf:params:oauth:grant-type:device_code"
    static let refreshToken = "refresh_token"

    /// A per-session client can sign in through the browser or a device code and refresh either.
    static let sessionClientGrants = [authorizationCode, deviceCode, refreshToken]

    /// The registered redirect URI. AWS accepts any loopback port at authorization time,
    /// as RFC 8252 §7.3 describes for native apps.
    static let redirectUri = "http://127.0.0.1/oauth/callback"
}

/// Failures inside the browser sign-in that the service maps or recovers from.
enum BrowserSignInError: Error, Equatable {
    /// The loopback callback could not start; the service falls back to a device code.
    case callbackUnavailable
    case timedOut
    case accessDenied
    case invalidCallback
}

/// Proof Key for Code Exchange values for one authorization request (RFC 7636, S256).
struct OAuthPKCE: Sendable {
    let verifier: String
    let state: String

    var challenge: String {
        Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func generate() throws -> OAuthPKCE {
        OAuthPKCE(verifier: try randomString(), state: try randomString())
    }

    /// The Identity Center authorize URL for this request.
    func authorizationURL(region: String, clientID: String, redirectURI: URL, scopes: [String]) throws -> URL {
        let suffix = region.hasPrefix("cn-") ? "amazonaws.com.cn" : "amazonaws.com"
        guard var components = URLComponents(string: "https://oidc.\(region).\(suffix)/authorize") else {
            throw IAMIdentityCenterError.malformedResponse("Invalid authorization endpoint for region \(region)")
        }
        let values = [
            ("response_type", "code"),
            ("client_id", clientID),
            ("redirect_uri", redirectURI.absoluteString),
            ("state", state),
            ("code_challenge_method", "S256"),
            ("code_challenge", challenge),
            // AWS's Authorize endpoint calls this parameter "scopes".
            ("scopes", scopes.joined(separator: " "))
        ]
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        components.percentEncodedQuery = values.map {
            "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        guard let url = components.url else {
            throw IAMIdentityCenterError.malformedResponse("Invalid authorization URL")
        }
        return url
    }

    private static func randomString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw IAMIdentityCenterError.malformedResponse("Could not generate random bytes")
        }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Parses the browser's request to the loopback callback.
enum OAuthCallbackRequest {
    static func code(from header: Data, port: UInt16, expectedState: String) throws -> String {
        guard header.count <= 8192, let text = String(data: header, encoding: .utf8) else {
            throw BrowserSignInError.invalidCallback
        }
        let lines = text.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ")
        guard request.count == 3, request[0] == "GET", request[2] == "HTTP/1.1",
              request[1].hasPrefix("/oauth/callback?"),
              let components = URLComponents(string: "http://127.0.0.1:\(port)\(request[1])"),
              components.path == "/oauth/callback", components.fragment == nil else {
            throw BrowserSignInError.invalidCallback
        }
        let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        guard hosts.count == 1,
              hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(port)" else {
            throw BrowserSignInError.invalidCallback
        }
        let items = components.queryItems ?? []
        func only(_ name: String) -> String? {
            let matches = items.filter { $0.name == name }
            return matches.count == 1 ? matches[0].value : nil
        }
        guard let state = only("state"), constantTimeEqual(state, expectedState) else {
            throw BrowserSignInError.invalidCallback
        }
        let errors = items.filter { $0.name == "error" }
        if !errors.isEmpty {
            guard errors.count == 1, only("error")?.isEmpty == false,
                  !items.contains(where: { $0.name == "code" }) else { throw BrowserSignInError.invalidCallback }
            throw BrowserSignInError.accessDenied
        }
        guard let code = only("code"), !code.isEmpty, code.count <= 4096 else {
            throw BrowserSignInError.invalidCallback
        }
        return code
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// The browser sign-in's loopback callback: a `GET /oauth/callback` on a port the system chooses,
/// open for ten minutes.
@MainActor
final class LoopbackOAuthListener {
    nonisolated static let defaultLifetime: Duration = .seconds(600)

    private let listener: LoopbackCallbackListener<String>

    /// `sessionName` is only shown on the page the browser lands on.
    init(expectedState: String, sessionName: String, lifetime: Duration = LoopbackOAuthListener.defaultLifetime) {
        listener = LoopbackCallbackListener(
            limits: .init(header: 8192, body: 0),
            lifetime: lifetime,
            unavailable: BrowserSignInError.callbackUnavailable,
            timedOut: BrowserSignInError.timedOut,
            rejectedPage: SignInCallbackPage.notAccepted.page
        ) { request, port in
            do {
                let code = try OAuthCallbackRequest.code(from: request.head, port: port, expectedState: expectedState)
                return .init(page: SignInCallbackPage.received(sessionName: sessionName).page, outcome: .success(code))
            } catch BrowserSignInError.accessDenied {
                return .init(page: SignInCallbackPage.declined(sessionName: sessionName).page, outcome: .failure(BrowserSignInError.accessDenied))
            } catch {
                // Unrelated requests and a wrong state must not cancel a valid sign-in.
                return .init(page: SignInCallbackPage.notAccepted.page, outcome: nil)
            }
        }
    }

    /// Starts listening and returns the redirect URI, including the port the system chose.
    func start() async throws -> URL {
        URL(string: "http://127.0.0.1:\(try await listener.start())/oauth/callback")!
    }

    /// Waits for the browser to deliver the authorization code.
    func authorizationCode() async throws -> String {
        try await listener.value()
    }

    func cancel() {
        listener.cancel()
    }
}
