import Foundation
import Network

nonisolated struct PostgreSQLUpstreamSession: Sendable {
    let socket: PostgreSQLSocket
    let parameters: [Data]
    let backendKey: Data?
}

nonisolated protocol PostgreSQLUpstreamConnecting: Sendable {
    func connect(configuration: DatabaseConnectionSummary, binding: DatabaseRoleBinding?, parameters: [String: String]) async throws -> PostgreSQLUpstreamSession
    func cancel(configuration: DatabaseConnectionSummary, backendKey: Data) async throws
}

actor PostgreSQLConnector: PostgreSQLUpstreamConnecting {
    private let credentialService: any DatabaseRoleCredentialProviding
    private let tokens = RDSIAMTokenGenerator()
    private let diagnostics: DiagnosticLog
    private let passwordLogin: @Sendable (UUID) async throws -> DatabaseLogin
    private let tlsOptions: (@Sendable (String, DatabaseTLSOptions.TrustSource) throws -> NWProtocolTLS.Options)?

    init(service: any DatabaseRoleCredentialProviding, diagnostics: DiagnosticLog = .disabled,
         passwordLogin: @escaping @Sendable (UUID) async throws -> DatabaseLogin = { _ in throw ConfigurationError.missingCredential },
         tlsOptions: (@Sendable (String, DatabaseTLSOptions.TrustSource) throws -> NWProtocolTLS.Options)? = nil) {
        credentialService = service
        self.diagnostics = diagnostics
        self.passwordLogin = passwordLogin
        self.tlsOptions = tlsOptions
    }

    func connect(configuration: DatabaseConnectionSummary, binding: DatabaseRoleBinding? = nil, parameters: [String: String]) async throws -> PostgreSQLUpstreamSession {
        let draft = configuration.draft
        try configuration.validate(binding: binding)
        diagnostics.record(.upstreamConnecting, connectionID: configuration.id)
        let login: DatabaseLogin
        if let binding {
            let credentials = try await credentialService.credentials(for: binding)
            try Task.checkCancellation()
            let token = try await tokens.generate(credentials: credentials, host: draft.host, port: draft.upstreamPort,
                                                  region: draft.region, username: draft.username)
            login = DatabaseLogin(username: draft.username, password: token)
        } else {
            login = try await passwordLogin(configuration.credentialID)
        }
        try Task.checkCancellation()
        guard !login.username.contains("\0"), !login.password.contains("\0") else { throw ProxyError.upstreamPasswordAuthentication }
        let socket = try makeSocket(configuration)
        do {
            try await socket.start()
            var startup = parameters
            startup["user"] = login.username
            startup["database"] = draft.database
            // The local side negotiates protocol 3.0 and handles extensions.
            startup = startup.filter { !$0.key.hasPrefix("_pq_.") }
            try await socket.send(PostgreSQLWire.startup(startup))
            var authentication = try PostgreSQLPasswordAuthentication(login: login, iam: draft.authentication == .awsIAM)
            var statusMessages: [Data] = []
            var backendKey: Data?
            var handshakeBytes = 0
            for _ in 0..<128 {
                let response = try await socket.message()
                handshakeBytes += response.body.count
                guard handshakeBytes <= PostgreSQLWire.maximumHandshakeMessage else { throw ProxyError.malformedMessage }
                switch response.type {
                case 82: // AuthenticationRequest
                    if let reply = try authentication.respond(to: response.body) {
                        try Task.checkCancellation()
                        try await socket.send(PostgreSQLWire.message(112, reply))
                    }
                case 83: // ParameterStatus
                    guard authentication.complete else { throw ProxyError.malformedMessage }
                    statusMessages.append(PostgreSQLWire.message(response.type, response.body))
                case 75: // BackendKeyData for protocol 3.0
                    guard authentication.complete, response.body.count == 8, backendKey == nil else { throw ProxyError.malformedMessage }
                    backendKey = response.body
                case 90: // ReadyForQuery
                    guard authentication.complete, response.body == Data([73]) else { throw ProxyError.malformedMessage }
                    diagnostics.record(.upstreamAuthenticated, connectionID: configuration.id)
                    return .init(socket: socket, parameters: statusMessages, backendKey: backendKey)
                case 78: break // Do not copy authentication-stage notices into logs or local errors.
                case 69: throw draft.authentication == .awsIAM ? ProxyError.upstreamAuthentication : ProxyError.upstreamPasswordAuthentication
                default: throw ProxyError.malformedMessage
                }
            }
            throw ProxyError.malformedMessage
        } catch {
            socket.close()
            diagnostics.record(.upstreamFailed, connectionID: configuration.id, error: error)
            throw error
        }
    }

    func cancel(configuration: DatabaseConnectionSummary, backendKey: Data) async throws {
        guard backendKey.count == 8 else { throw ProxyError.malformedMessage }
        let socket = try makeSocket(configuration)
        defer { socket.close() }
        try await socket.start()
        try await socket.send(PostgreSQLWire.integer(16) + PostgreSQLWire.integer(PostgreSQLWire.cancelRequest) + backendKey)
        // PostgreSQL acknowledges cancellation only by closing this connection.
        _ = try await socket.chunk(maximum: 1)
    }

    private func makeSocket(_ configuration: DatabaseConnectionSummary) throws -> PostgreSQLSocket {
        let draft = configuration.draft
        guard draft.authentication != .awsIAM || draft.tlsMode == .verified else { throw ConfigurationError.iamRequiresTLS }
        guard let port = NWEndpoint.Port(rawValue: UInt16(exactly: draft.upstreamPort) ?? 0), port.rawValue != 0 else {
            throw ConfigurationError.invalidPort("Upstream port")
        }
        let parameters = NWParameters.tcp
        if draft.tlsMode == .verified {
            let tls = try tlsOptions?(draft.host, draft.trust) ?? DatabaseTLSOptions.make(hostname: draft.host, trust: draft.trust,
                                                                                      diagnostics: diagnostics, connectionID: configuration.id)
            parameters.defaultProtocolStack.applicationProtocols.insert(PostgreSQLTLSFramer.options(tls: tls), at: 0)
        }
        return PostgreSQLSocket(NWConnection(host: .init(draft.host), port: port, using: parameters))
    }
}
