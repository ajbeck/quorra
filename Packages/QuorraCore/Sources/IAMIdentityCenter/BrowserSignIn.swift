import CryptoKit
import Foundation
import Network
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

/// One-use HTTP callback server for a browser sign-in. It binds only to IPv4 loopback, has a
/// ten-minute lifetime, caps request size and concurrency, and never logs or echoes callback data.
@MainActor
final class LoopbackOAuthListener {
    nonisolated static let defaultLifetime: Duration = .seconds(600)

    private let expectedState: String
    private let sessionName: String
    private let lifetime: Duration
    private var listener: NWListener?
    private var ready: CheckedContinuation<URL, any Error>?
    private var codeContinuation: CheckedContinuation<String, any Error>?
    private var outcome: Result<String, any Error>?
    private var timeout: Task<Void, Never>?
    private var connections: [UUID: NWConnection] = [:]
    private var connectionTimeouts: [UUID: Task<Void, Never>] = [:]
    private var port: UInt16 = 0

    /// `sessionName` is only shown on the page the browser lands on.
    init(expectedState: String, sessionName: String, lifetime: Duration = LoopbackOAuthListener.defaultLifetime) {
        self.expectedState = expectedState
        self.sessionName = sessionName
        self.lifetime = lifetime
    }

    /// Starts listening and returns the redirect URI, including the port the system chose.
    func start() async throws -> URL {
        try Task.checkCancellation()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) }
        catch { throw BrowserSignInError.callbackUnavailable }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.outcome == nil else { return }
                switch state {
                case .ready:
                    guard let port = self.listener?.port?.rawValue else {
                        self.finish(.failure(BrowserSignInError.callbackUnavailable))
                        return
                    }
                    self.port = port
                    self.ready?.resume(returning: URL(string: "http://127.0.0.1:\(port)/oauth/callback")!)
                    self.ready = nil
                case .failed:
                    self.finish(.failure(BrowserSignInError.callbackUnavailable))
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        let lifetime = lifetime
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: lifetime) } catch { return }
            self?.finish(.failure(BrowserSignInError.timedOut))
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                ready = $0
                if Task.isCancelled { cancel() } else { listener.start(queue: .main) }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    /// Waits for the browser to deliver the authorization code.
    func authorizationCode() async throws -> String {
        try await withTaskCancellationHandler {
            if let outcome { return try outcome.get() }
            return try await withCheckedThrowingContinuation {
                codeContinuation = $0
                if Task.isCancelled { cancel() }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func accept(_ connection: NWConnection) {
        guard outcome == nil, connections.count < 8 else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection
        connectionTimeouts[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.close(id)
        }
        connection.start(queue: .main)
        receive(id, accumulated: Data())
    }

    private func receive(_ id: UUID, accumulated: Data) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192 - accumulated.count) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var buffer = accumulated
                if let data { buffer.append(data) }
                if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    self.handle(id, header: buffer.subdata(in: 0..<end.upperBound))
                } else if error != nil || complete || buffer.count >= 8192 {
                    self.close(id)
                } else {
                    self.receive(id, accumulated: buffer)
                }
            }
        }
    }

    private func handle(_ id: UUID, header: Data) {
        do {
            let code = try OAuthCallbackRequest.code(from: header, port: port, expectedState: expectedState)
            respond(id, page: .received(sessionName: sessionName), result: .success(code))
        } catch BrowserSignInError.accessDenied {
            respond(id, page: .declined(sessionName: sessionName), result: .failure(BrowserSignInError.accessDenied))
        } catch {
            // Unrelated requests and a wrong state must not cancel a valid sign-in.
            respond(id, page: .notAccepted, result: nil)
        }
    }

    private func respond(_ id: UUID, page: SignInCallbackPage, result: Result<String, any Error>?) {
        let body = page.html
        let response = "HTTP/1.1 \(page.statusLine)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: \(SignInCallbackPage.contentSecurityPolicy)\r\nConnection: close\r\n\r\n\(body)"
        connections[id]?.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                self?.close(id)
                if let result { self?.finish(result) }
            }
        })
    }

    private func close(_ id: UUID) {
        connectionTimeouts.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }

    private func finish(_ result: Result<String, any Error>) {
        guard outcome == nil else { return }
        outcome = result
        timeout?.cancel()
        listener?.cancel()
        listener = nil
        for id in Array(connections.keys) {
            close(id)
        }
        if let ready {
            self.ready = nil
            switch result {
            case .failure(let error):
                ready.resume(throwing: error)
            case .success:
                ready.resume(throwing: BrowserSignInError.invalidCallback)
            }
        }
        codeContinuation?.resume(with: result)
        codeContinuation = nil
    }
}
