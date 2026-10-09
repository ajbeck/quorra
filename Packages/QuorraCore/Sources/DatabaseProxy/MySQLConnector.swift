import Foundation
import Network

nonisolated struct MySQLUpstreamSession: Sendable {
    let socket: PostgreSQLSocket
    let ok: Data
}

nonisolated protocol MySQLUpstreamConnecting: Sendable {
    func connect(configuration: DatabaseConnectionSummary, binding: DatabaseRoleBinding?, capabilities: UInt32,
                 characterSet: UInt8, attributes: Data) async throws -> MySQLUpstreamSession
}

actor MySQLConnector: MySQLUpstreamConnecting {
    private let credentials: any DatabaseRoleCredentialProviding
    private let tokens = RDSIAMTokenGenerator()
    private let passwordLogin: @Sendable (UUID) async throws -> DatabaseLogin
    private let diagnostics: DiagnosticLog
    private let tlsOptions: (@Sendable (String, DatabaseTLSOptions.TrustSource) throws -> NWProtocolTLS.Options)?

    init(service: any DatabaseRoleCredentialProviding, diagnostics: DiagnosticLog = .disabled,
         passwordLogin: @escaping @Sendable (UUID) async throws -> DatabaseLogin = { _ in throw ConfigurationError.missingCredential },
         tlsOptions: (@Sendable (String, DatabaseTLSOptions.TrustSource) throws -> NWProtocolTLS.Options)? = nil) {
        credentials = service; self.diagnostics = diagnostics; self.passwordLogin = passwordLogin; self.tlsOptions = tlsOptions
    }

    func connect(configuration: DatabaseConnectionSummary, binding: DatabaseRoleBinding? = nil,
                 capabilities: UInt32 = MySQLWire.capabilities, characterSet: UInt8 = 45, attributes: Data = Data()) async throws -> MySQLUpstreamSession {
        try configuration.validate(binding: binding)
        let draft = configuration.draft
        guard draft.engine == .mysql else { throw ProxyError.unsupportedMySQLProtocol }
        diagnostics.record(.upstreamConnecting, connectionID: configuration.id)
        let login: DatabaseLogin
        if let binding {
            let role = try await credentials.credentials(for: binding)
            let token = try await tokens.generate(credentials: role, host: draft.host, port: draft.upstreamPort, region: draft.region, username: draft.username)
            login = DatabaseLogin(username: draft.username, password: token)
        } else { login = try await passwordLogin(configuration.credentialID) }
        try Task.checkCancellation()
        let verifiedTLS = draft.tlsMode == .verified
        let tls: NWProtocolTLS.Options? = verifiedTLS
            ? try (tlsOptions?(draft.host, draft.trust) ?? DatabaseTLSOptions.make(hostname: draft.host, trust: draft.trust, diagnostics: diagnostics, connectionID: configuration.id)) : nil
        let state = MySQLHandshakeState()
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(MySQLTLSFramer.options(tls: tls, state: state,
                                                                                           capabilities: capabilities, characterSet: characterSet), at: 0)
        guard let port = NWEndpoint.Port(rawValue: UInt16(exactly: draft.upstreamPort) ?? 0), port.rawValue != 0 else {
            throw ConfigurationError.invalidPort("Upstream port")
        }
        let socket = PostgreSQLSocket(NWConnection(host: .init(draft.host), port: port, using: parameters))
        do {
            try await socket.start()
            let result = state.value.withLock { $0 }
            guard let greeting = result.greeting else { throw ProxyError.malformedMySQLMessage }
            var sequence = result.sequence
            var plugin = greeting.plugin
            var nonce = greeting.nonce
            let iam = draft.authentication == .awsIAM
            var sentCredential = !iam || plugin == "mysql_clear_password"
            let response = try MySQLAuthentication.response(plugin: plugin, password: login.password, nonce: nonce, verifiedTLS: verifiedTLS, iam: iam)
            var payload = MySQLWire.header(capabilities: result.capabilities, characterSet: characterSet)
            payload += Data(login.username.utf8) + Data([0])
            if result.capabilities & MySQLWire.lengthEncodedAuth != 0 { payload += MySQLWire.lengthEncoded(response) }
            else {
                guard response.count <= 255 else { throw ProxyError.unsupportedMySQLProtocol }
                payload += Data([UInt8(response.count)]) + response
            }
            payload += Data(draft.database.utf8) + Data([0])
            if result.capabilities & MySQLWire.pluginAuth != 0 { payload += Data(plugin.utf8) + Data([0]) }
            if result.capabilities & MySQLWire.connectAttributes != 0 { payload += MySQLWire.lengthEncoded(attributes) }
            try await socket.send(MySQLWire.packet(payload, sequence: sequence)); sequence &+= 1
            var switched = false, fullPasswordSent = false, fastAuthenticated = false
            for _ in 0..<8 {
                let packet = try await MySQLWire.read(socket, sequence: sequence); sequence &+= 1
                guard let type = packet.first else { throw ProxyError.malformedMySQLMessage }
                switch type {
                case 0:
                    guard sentCredential, packet.count >= 7 else { throw ProxyError.upstreamPasswordAuthentication }
                    diagnostics.record(.upstreamAuthenticated, connectionID: configuration.id)
                    return .init(socket: socket, ok: packet)
                case 255: throw iam ? ProxyError.upstreamAuthentication : ProxyError.upstreamPasswordAuthentication
                case 254:
                    guard !switched, !fullPasswordSent, !fastAuthenticated else { throw ProxyError.malformedMySQLMessage }
                    switched = true
                    var cursor = MySQLWire.Cursor(Data(packet.dropFirst()))
                    plugin = try cursor.string()
                    let challenge = try cursor.take(cursor.remaining)
                    // mysql_clear_password can omit auth-plugin-data entirely.
                    if plugin != "mysql_clear_password" {
                        guard challenge.count == 20 || (challenge.count == 21 && challenge.last == 0) else { throw ProxyError.malformedMySQLMessage }
                        nonce = Data(challenge.prefix(20))
                    }
                    if iam, plugin != "mysql_clear_password" { throw ProxyError.upstreamAuthentication }
                    let answer = try MySQLAuthentication.response(plugin: plugin, password: login.password, nonce: nonce, verifiedTLS: verifiedTLS, iam: iam)
                    try await socket.send(MySQLWire.packet(answer, sequence: sequence)); sequence &+= 1
                    sentCredential = true
                case 1:
                    guard !iam, plugin == "caching_sha2_password", packet.count == 2, !fullPasswordSent, !fastAuthenticated else {
                        throw ProxyError.unsupportedMySQLProtocol
                    }
                    if packet[1] == 3 { fastAuthenticated = true }
                    else if packet[1] == 4 {
                        guard verifiedTLS else { throw ProxyError.mysqlAuthenticationRequiresTLS }
                        try await socket.send(MySQLWire.packet(Data(login.password.utf8) + Data([0]), sequence: sequence)); sequence &+= 1
                        fullPasswordSent = true
                    } else { throw ProxyError.unsupportedMySQLProtocol }
                default: throw ProxyError.unsupportedMySQLProtocol
                }
            }
            throw ProxyError.malformedMySQLMessage
        } catch {
            socket.close()
            let failure: any Error = state.value.withLock { $0.failure } ?? error
            diagnostics.record(.upstreamFailed, connectionID: configuration.id, error: failure)
            throw failure
        }
    }
}
