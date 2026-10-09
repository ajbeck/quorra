import Foundation
import IAMIdentityCenter
import Network
import Observation

nonisolated struct ProxyEndpointStatus: Sendable {
    enum State: String, Sendable {
        case stopped = "Stopped", starting = "Starting", checkingUpstream = "Checking upstream"
        case listening = "Listening", failed = "Failed"
    }
    var state: State = .stopped
    var activeConnections = 0
    var issue: String?
}

@MainActor
@Observable
final class ProxyCoordinator {
    private(set) var statuses: [UUID: ProxyEndpointStatus] = [:]
    private let credentials: any DatabaseRoleCredentialProviding
    private let upstream: any PostgreSQLUpstreamConnecting
    private let mysql: (any MySQLUpstreamConnecting)?
    private let diagnostics: DiagnosticLog
    private let upstreamCheckTimeout: Duration
    @ObservationIgnored private var endpoints: [UUID: Endpoint] = [:]
    private var shuttingDown = false

    init(credentials: any DatabaseRoleCredentialProviding, upstream: any PostgreSQLUpstreamConnecting,
         mysql: (any MySQLUpstreamConnecting)? = nil, diagnostics: DiagnosticLog = .disabled,
         upstreamCheckTimeout: Duration = .seconds(30)) {
        self.credentials = credentials
        self.upstream = upstream
        self.mysql = mysql
        self.diagnostics = diagnostics
        self.upstreamCheckTimeout = upstreamCheckTimeout
    }

    func isActive(_ id: UUID) -> Bool { endpoints[id] != nil }

    func start(_ configuration: DatabaseConnectionSummary, binding: DatabaseRoleBinding? = nil, password: String?) async throws {
        guard !shuttingDown else { throw ProxyError.stopped }
        guard endpoints[configuration.id] == nil else { return }
        try configuration.validate(binding: binding)
        if configuration.draft.localAuthentication == .generatedPassword, password == nil { throw ProxyError.localAuthentication }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .init(rawValue: UInt16(configuration.draft.localPort))!)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) }
        catch {
            let failure = Self.listenerError(error)
            statuses[configuration.id] = .init(state: .failed, issue: Self.message(failure))
            diagnostics.record(.endpointFailed, connectionID: configuration.id, error: failure)
            throw failure
        }
        let endpoint = Endpoint(configuration: configuration, binding: binding, password: password, listener: listener)
        endpoints[configuration.id] = endpoint
        statuses[configuration.id] = .init(state: .starting)
        diagnostics.record(.endpointStarting, connectionID: configuration.id)
        do {
            // Mint before listening so a missing sign-in fails Start rather than the first client.
            let startup = Task {
                if let binding { _ = try await credentials.credentials(for: binding) }
                try Task.checkCancellation()
                guard endpoints[configuration.id] === endpoint else { throw CancellationError() }
                statuses[configuration.id]?.state = .checkingUpstream
                diagnostics.record(.endpointCheckingUpstream, connectionID: configuration.id)
                try await checkUpstream(configuration, binding: binding)
                try Task.checkCancellation()
                guard endpoints[configuration.id] === endpoint else { throw CancellationError() }
                diagnostics.record(.endpointUpstreamVerified, connectionID: configuration.id)
                statuses[configuration.id]?.state = .starting
            }
            endpoint.startup = startup
            defer { endpoint.startup = nil }
            try await withTaskCancellationHandler { try await startup.value } onCancel: { startup.cancel() }
            try Task.checkCancellation()
            guard endpoints[configuration.id] === endpoint else { throw CancellationError() }
            listener.stateUpdateHandler = { [weak self, weak endpoint] state in
                Task { @MainActor in
                    guard let self, let endpoint, self.endpoints[configuration.id] === endpoint else { return }
                    switch state {
                    case .ready:
                        self.diagnostics.record(.endpointListening, connectionID: configuration.id)
                        self.statuses[configuration.id]?.state = .listening
                        endpoint.ready?.resume(); endpoint.ready = nil
                    case .failed(let error):
                        let failure = Self.listenerError(error)
                        self.diagnostics.record(.endpointFailed, connectionID: configuration.id, error: failure)
                        endpoint.ready?.resume(throwing: failure); endpoint.ready = nil
                        if self.statuses[configuration.id]?.state == .listening {
                            await self.stop(configuration.id)
                            if self.endpoints[configuration.id] == nil {
                                self.statuses[configuration.id] = .init(state: .failed, issue: failure.localizedDescription)
                            }
                        }
                    case .cancelled:
                        endpoint.ready?.resume(throwing: CancellationError()); endpoint.ready = nil
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self, weak endpoint] connection in
                Task { @MainActor in
                    guard let self, let endpoint, self.endpoints[configuration.id] === endpoint else { connection.cancel(); return }
                    guard endpoint.clients.count < 64 else {
                        self.diagnostics.record(.clientRejected, connectionID: configuration.id, count: endpoint.clients.count)
                        connection.cancel(); return
                    }
                    self.accept(connection, endpoint: endpoint)
                }
            }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    endpoint.ready = continuation
                    listener.start(queue: .main)
                    if Task.isCancelled { listener.cancel() }
                }
            } onCancel: { listener.cancel() }
        } catch {
            if !(error is CancellationError) {
                diagnostics.record(.endpointFailed, connectionID: configuration.id, error: error)
            }
            if endpoints[configuration.id] === endpoint {
                let checkingUpstream = statuses[configuration.id]?.state == .checkingUpstream
                await stop(configuration.id)
                if !(error is CancellationError), endpoints[configuration.id] == nil {
                    let message = checkingUpstream ? "Upstream check failed: \(Self.message(error))" : Self.message(error)
                    statuses[configuration.id] = .init(state: .failed, issue: message)
                }
            }
            throw error
        }
    }

    func stop(_ id: UUID) async {
        guard let endpoint = endpoints.removeValue(forKey: id) else { return }
        diagnostics.record(.endpointStopped, connectionID: id, count: endpoint.clients.count)
        endpoint.startup?.cancel()
        endpoint.listener.cancel()
        endpoint.ready?.resume(throwing: CancellationError()); endpoint.ready = nil
        for client in endpoint.clients.values {
            client.local.close(); client.remote?.close(); client.task?.cancel()
        }
        endpoint.cancelKeys.removeAll()
        statuses[id] = .init()
    }

    func test(_ configuration: DatabaseConnectionSummary, binding: DatabaseRoleBinding? = nil) async throws {
        guard !shuttingDown else { throw ProxyError.stopped }
        diagnostics.record(.connectionTestStarted, connectionID: configuration.id)
        try configuration.validate(binding: binding)
        do { try await checkUpstream(configuration, binding: binding) }
        catch {
            diagnostics.record(.connectionTestFailed, connectionID: configuration.id, error: error)
            throw error
        }
        diagnostics.record(.connectionTestSucceeded, connectionID: configuration.id)
    }

    /// Authenticate using the same connector as local clients, then terminate
    /// the disposable session. No SQL or long-lived upstream connection is needed.
    private func checkUpstream(_ configuration: DatabaseConnectionSummary, binding: DatabaseRoleBinding?) async throws {
        let task = Task {
            if configuration.draft.engine == .postgresql {
                let session = try await upstream.connect(configuration: configuration, binding: binding, parameters: ["application_name": "Quorra connection test"])
                defer { session.socket.close() }
                try await session.socket.send(PostgreSQLWire.message(88))
            } else {
                guard let mysql else { throw ProxyError.unsupportedMySQLProtocol }
                let session = try await mysql.connect(configuration: configuration, binding: binding,
                                                      capabilities: MySQLWire.capabilities, characterSet: 45, attributes: Data())
                defer { session.socket.close() }
                try await session.socket.send(MySQLWire.packet(Data([1]), sequence: 0))
            }
        }
        var timedOut = false
        let timeout = Task { try? await Task.sleep(for: upstreamCheckTimeout); if !Task.isCancelled { timedOut = true; task.cancel() } }
        defer { timeout.cancel() }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            if timedOut { throw ProxyError.timedOut }
        }
        catch {
            if Task.isCancelled { throw CancellationError() }
            if timedOut { throw ProxyError.timedOut }; throw error
        }
    }

    func shutdown() async {
        shuttingDown = true
        for id in Array(endpoints.keys) { await stop(id) }
    }

    private func accept(_ connection: NWConnection, endpoint: Endpoint) {
        let client = Client(local: PostgreSQLSocket(connection))
        endpoint.clients[client.id] = client
        diagnostics.record(.clientAccepted, connectionID: endpoint.configuration.id, clientID: client.id)
        client.task = Task { [weak self] in
            guard let self else { client.local.close(); return }
            let timeout = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                self.diagnostics.record(.handshakeTimedOut, connectionID: endpoint.configuration.id, clientID: client.id)
                if self.endpoints[endpoint.configuration.id] === endpoint {
                    self.statuses[endpoint.configuration.id]?.issue = ProxyError.timedOut.localizedDescription
                }
                client.local.close(); client.remote?.close(); client.task?.cancel()
            }
            defer {
                self.diagnostics.record(.clientClosed, connectionID: endpoint.configuration.id, clientID: client.id)
                timeout.cancel()
                client.local.close(); client.remote?.close()
                endpoint.clients[client.id] = nil
                if let key = client.cancelKey { endpoint.cancelKeys[key] = nil }
                if client.established, self.endpoints[endpoint.configuration.id] === endpoint {
                    self.statuses[endpoint.configuration.id]?.activeConnections -= 1
                }
            }
            do {
                try await client.local.start()
                if endpoint.configuration.draft.engine == .mysql {
                    let remote = try await self.authenticateMySQL(client, endpoint: endpoint)
                    timeout.cancel()
                    client.established = true
                    self.diagnostics.record(.clientAuthenticated, connectionID: endpoint.configuration.id, clientID: client.id)
                    self.statuses[endpoint.configuration.id]?.activeConnections += 1
                    self.statuses[endpoint.configuration.id]?.issue = nil
                    try await Self.relay(client.local, remote)
                    return
                }
                guard let parameters = try await self.startup(client, endpoint: endpoint) else { return }
                if endpoint.configuration.draft.localAuthentication == .generatedPassword {
                    guard let password = endpoint.password else { throw ProxyError.localAuthentication }
                    try await PostgreSQLSCRAM.authenticate(client.local, password: password)
                }
                let session = try await self.upstream.connect(configuration: endpoint.configuration, binding: endpoint.binding, parameters: parameters)
                client.remote = session.socket
                try Task.checkCancellation()
                guard self.endpoints[endpoint.configuration.id] === endpoint else { throw CancellationError() }
                try await client.local.send(PostgreSQLWire.authentication(0))
                for message in session.parameters { try await client.local.send(message) }
                if let backendKey = session.backendKey {
                    // Never expose the upstream cancellation secret. Keys are
                    // scoped to this endpoint and removed with their session.
                    var localKey = try ProxyRandom.bytes(8)
                    localKey[0] &= 0x7f
                    if localKey.prefix(4).allSatisfy({ $0 == 0 }) { localKey[3] = 1 }
                    while endpoint.cancelKeys[localKey] != nil {
                        localKey = try ProxyRandom.bytes(8)
                        localKey[0] &= 0x7f
                        if localKey.prefix(4).allSatisfy({ $0 == 0 }) { localKey[3] = 1 }
                    }
                    endpoint.cancelKeys[localKey] = backendKey
                    client.cancelKey = localKey
                    try await client.local.send(PostgreSQLWire.message(75, localKey))
                }
                try await client.local.send(PostgreSQLWire.message(90, Data([73])))
                timeout.cancel()
                client.established = true
                self.diagnostics.record(.clientAuthenticated, connectionID: endpoint.configuration.id, clientID: client.id)
                self.statuses[endpoint.configuration.id]?.activeConnections += 1
                self.statuses[endpoint.configuration.id]?.issue = nil
                try await Self.relay(client.local, session.socket)
            } catch {
                if !Task.isCancelled {
                    self.diagnostics.record(.clientFailed, connectionID: endpoint.configuration.id, clientID: client.id, error: error)
                    if self.endpoints[endpoint.configuration.id] === endpoint {
                        self.statuses[endpoint.configuration.id]?.issue = Self.message(error)
                    }
                }
                if !Task.isCancelled, !client.established {
                    let response = endpoint.configuration.draft.engine == .mysql
                        ? MySQLWire.packet(MySQLWire.error(error), sequence: client.mysqlSequence)
                        : PostgreSQLWire.error(error)
                    try? await client.local.send(response)
                }
            }
        }
    }

    private func authenticateMySQL(_ client: Client, endpoint: Endpoint) async throws -> PostgreSQLSocket {
        guard let mysql else { throw ProxyError.unsupportedMySQLProtocol }
        let nonce = Data(try ProxyRandom.bytes(20).map { $0 == 0 ? 1 : $0 })
        let identifier = try ProxyRandom.bytes(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        try await client.local.send(MySQLWire.packet(MySQLWire.greeting(nonce: nonce, connectionID: identifier), sequence: 0))
        client.mysqlSequence = 1
        let payload = try await MySQLWire.read(client.local, sequence: 1)
        client.mysqlSequence = 2
        let handshake = try MySQLWire.ClientHandshake(payload)
        guard handshake.username == DatabaseConnectionDraft.localUsername else { throw ProxyError.localAuthentication }
        if let database = handshake.database, !database.isEmpty, database != endpoint.configuration.draft.database {
            throw ProxyError.databaseMismatch
        }
        guard ["caching_sha2_password", "mysql_native_password"].contains(handshake.plugin) else {
            throw ProxyError.unsupportedMySQLProtocol
        }
        if endpoint.configuration.draft.localAuthentication == .generatedPassword {
            guard let password = endpoint.password else { throw ProxyError.localAuthentication }
            try MySQLAuthentication.verifyLocal(handshake, password: password, nonce: nonce)
        }
        let session = try await mysql.connect(configuration: endpoint.configuration, binding: endpoint.binding,
                                              capabilities: handshake.capabilities, characterSet: handshake.characterSet, attributes: handshake.attributes)
        client.remote = session.socket
        try Task.checkCancellation()
        guard endpoints[endpoint.configuration.id] === endpoint else { throw CancellationError() }
        // A SHA2 client without a password sends a single zero byte and expects
        // OK directly. Only the 32-byte scramble needs the fast-auth response.
        if handshake.plugin == "caching_sha2_password", handshake.response.count == 32 {
            try await client.local.send(MySQLWire.packet(Data([1, 3]), sequence: client.mysqlSequence)); client.mysqlSequence &+= 1
        }
        try await client.local.send(MySQLWire.packet(session.ok, sequence: client.mysqlSequence))
        return session.socket
    }

    private func startup(_ client: Client, endpoint: Endpoint) async throws -> [String: String]? {
        var requestedSSL = false, requestedGSS = false
        for _ in 0..<3 {
            let size = Int(try PostgreSQLWire.uint32(await client.local.exact(4)))
            guard (8...PostgreSQLWire.maximumStartup).contains(size) else { throw ProxyError.malformedMessage }
            let body = try await client.local.exact(size - 4)
            let code = try PostgreSQLWire.uint32(Data(body.prefix(4)))
            if code == PostgreSQLWire.sslRequest, size == 8, !requestedSSL {
                requestedSSL = true
                try await client.local.send(Data([78])); continue
            }
            if code == PostgreSQLWire.gssRequest, size == 8, !requestedGSS {
                requestedGSS = true
                try await client.local.send(Data([78])); continue
            }
            if code == PostgreSQLWire.cancelRequest {
                guard size == 16 else { return nil }
                if let key = endpoint.cancelKeys[Data(body.dropFirst(4))] {
                    do {
                        try await upstream.cancel(configuration: endpoint.configuration, backendKey: key)
                        diagnostics.record(.cancellationForwarded, connectionID: endpoint.configuration.id, clientID: client.id)
                    } catch {
                        diagnostics.record(.cancellationFailed, connectionID: endpoint.configuration.id, clientID: client.id, error: error)
                    }
                }
                return nil
            }
            guard code >> 16 == 3 else { throw ProxyError.unsupportedProtocol }
            var parameters = try PostgreSQLWire.parameters(Data(body.dropFirst(4)))
            guard parameters["user"] == DatabaseConnectionDraft.localUsername else { throw ProxyError.localAuthentication }
            guard (parameters["database"] ?? parameters["user"]) == endpoint.configuration.draft.database else { throw ProxyError.databaseMismatch }
            guard parameters["replication"] == nil || parameters["replication"] == "false" else { throw ProxyError.unsupportedProtocol }
            let extensions = parameters.keys.filter { $0.hasPrefix("_pq_.") }.sorted()
            if code & 0xffff != 0 || !extensions.isEmpty {
                var negotiation = PostgreSQLWire.integer(0) + PostgreSQLWire.integer(UInt32(extensions.count))
                for name in extensions { negotiation.append(Data(name.utf8)); negotiation.append(0); parameters[name] = nil }
                try await client.local.send(PostgreSQLWire.message(118, negotiation))
            }
            return parameters
        }
        throw ProxyError.malformedMessage
    }

    private nonisolated static func relay(_ local: PostgreSQLSocket, _ remote: PostgreSQLSocket) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { while let data = try await local.chunk() { try await remote.send(data) } }
            group.addTask { while let data = try await remote.chunk() { try await local.send(data) } }
            defer { group.cancelAll(); local.close(); remote.close() }
            _ = try await group.next()
        }
    }

    private static func listenerError(_ error: any Error) -> ProxyError {
        if let error = error as? NWError, case .posix(.EADDRINUSE) = error { return .portInUse }
        return .localListenerUnavailable
    }

    nonisolated static func message(_ error: any Error) -> String {
        if error is ProxyError || error is IAMIdentityCenterError || error is ConfigurationError {
            return error.localizedDescription
        }
        return ProxyError.upstreamUnavailable.localizedDescription
    }

    @MainActor private final class Endpoint {
        let configuration: DatabaseConnectionSummary
        let binding: DatabaseRoleBinding?
        let password: String?
        let listener: NWListener
        var startup: Task<Void, any Error>?
        var ready: CheckedContinuation<Void, any Error>?
        var clients: [UUID: Client] = [:]
        var cancelKeys: [Data: Data] = [:]
        init(configuration: DatabaseConnectionSummary, binding: DatabaseRoleBinding?, password: String?, listener: NWListener) {
            self.configuration = configuration; self.binding = binding; self.password = password; self.listener = listener
        }
    }

    @MainActor private final class Client {
        let id = UUID()
        let local: PostgreSQLSocket
        var remote: PostgreSQLSocket?
        var cancelKey: Data?
        var task: Task<Void, Never>?
        var established = false
        var mysqlSequence: UInt8 = 0
        init(local: PostgreSQLSocket) { self.local = local }
    }
}
