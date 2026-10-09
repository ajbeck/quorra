import Foundation
import Network
import Testing
@testable import DatabaseProxy

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct MySQLIAMTests {
    @Test func IAMTokenIsSentOnlyAfterVerifiedTLSAndClearPasswordSwitch() async throws {
        let fixture = try await ProxyCredentialFixture()
        let server = MySQLIAMServer()
        try await server.start()
        defer { server.stop() }
        var draft = fixture.configuration(upstreamPort: server.port, localPort: 13306).draft
        draft.engine = .mysql
        let configuration = DatabaseConnectionSummary(id: UUID(), draft: draft, credentialID: fixture.credentialID, sessionName: "Synthetic")
        let connector = MySQLConnector(service: fixture.service, tlsOptions: { _, _ in try ProxyTestTLS.client() })
        let session = try await connector.connect(configuration: configuration, binding: fixture.binding)
        defer { session.socket.close() }
        #expect(server.initialResponseWasEmpty)
        #expect(server.signedTokenCount == 1)
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        async let send: Void = session.socket.send(payload)
        #expect(try await session.socket.exact(payload.count) == payload)
        try await send
    }

    @Test func TLSRejectionPreventsIAMTokenAndPasswordTransmission() async throws {
        let fixture = try await ProxyCredentialFixture()
        let server = MySQLIAMServer()
        try await server.start()
        defer { server.stop() }
        var draft = fixture.configuration(upstreamPort: server.port, localPort: 13306).draft
        draft.engine = .mysql
        let configuration = DatabaseConnectionSummary(id: UUID(), draft: draft, credentialID: fixture.credentialID, sessionName: "Synthetic")
        let connector = MySQLConnector(service: fixture.service, tlsOptions: { _, _ in try ProxyTestTLS.client(hostname: "wrong.example.test") })
        await #expect(throws: ProxyError.upstreamTLS) { try await connector.connect(configuration: configuration, binding: fixture.binding) }
        #expect(server.signedTokenCount == 0)
        #expect(!server.receivedHandshake)
    }

    @Test(arguments: ["wrongPlugin", "rejectedToken", "wrongSequence"])
    func IAMRejectsUnsupportedSwitchRejectedTokenAndOutOfSequenceReply(scenario: String) async throws {
        let fixture = try await ProxyCredentialFixture()
        let server = MySQLIAMServer(scenario: scenario)
        try await server.start()
        defer { server.stop() }
        var draft = fixture.configuration(upstreamPort: server.port, localPort: 13306).draft
        draft.engine = .mysql
        let configuration = DatabaseConnectionSummary(id: UUID(), draft: draft, credentialID: fixture.credentialID, sessionName: "Synthetic")
        let connector = MySQLConnector(service: fixture.service, tlsOptions: { _, _ in try ProxyTestTLS.client() })
        let expected: ProxyError = scenario == "wrongSequence" ? .malformedMySQLMessage : .upstreamAuthentication
        await #expect(throws: expected) { try await connector.connect(configuration: configuration, binding: fixture.binding) }
        #expect(server.signedTokenCount == (scenario == "rejectedToken" ? 1 : 0))
    }
}

private nonisolated final class MySQLServerTLSFramer: NWProtocolFramerImplementation {
    static let label = "Synthetic MySQL TLS server"
    static let definition = NWProtocolFramer.Definition(implementation: MySQLServerTLSFramer.self)
    private let tls: NWProtocolTLS.Options?
    private var upgraded = false
    init(framer: NWProtocolFramer.Instance) { tls = framer.options["tls"] as? NWProtocolTLS.Options }
    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        let greeting = MySQLWire.greeting(nonce: Data(1...20), connectionID: 42, capabilities: MySQLWire.capabilities | MySQLWire.ssl)
        framer.writeOutput(data: MySQLWire.packet(greeting, sequence: 0))
        return .willMarkReady
    }
    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        if upgraded { return forwardInput(framer) }
        var request: Data?
        _ = framer.parseInput(minimumIncompleteLength: 36, maximumLength: 36) { bytes, _ in
            guard let bytes, bytes.count == 36 else { return 0 }
            request = Data(bytes); return 36
        }
        guard let request else { return 36 }
        guard request.prefix(4) == Data([32, 0, 0, 1]), request[5] & 8 != 0, let tls else {
            framer.markFailed(error: .posix(.EPROTO)); return 0
        }
        do { try framer.prependApplicationProtocol(options: tls) }
        catch { framer.markFailed(error: .posix(.EPROTO)); return 0 }
        upgraded = true
        framer.markReady(); framer.passThroughOutput()
        // A MySQL client can send SSLRequest and ClientHello together. Drain
        // already-buffered bytes explicitly after installing the TLS protocol.
        return forwardInput(framer)
    }
    private func forwardInput(_ framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var count = 0
            _ = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 65_536) { bytes, _ in
                count = bytes?.count ?? 0
                return 0
            }
            guard count > 0 else { return 1 }
            guard framer.deliverInputNoCopy(length: count, message: .init(definition: Self.definition), isComplete: true) else { return 1 }
        }
    }
    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        try? framer.writeOutputNoCopy(length: messageLength)
    }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}
}

@MainActor
final class MySQLIAMServer {
    private let scenario: String
    init(scenario: String = "accepted") { self.scenario = scenario }
    private var listener: NWListener?
    private var ready: CheckedContinuation<Void, any Error>?
    private var sockets: [PostgreSQLSocket] = []
    private(set) var signedTokenCount = 0
    private(set) var closedConnectionCount = 0
    private(set) var initialResponseWasEmpty = false
    private(set) var receivedHandshake = false
    var port: Int { Int(listener?.port?.rawValue ?? 0) }

    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let options = NWProtocolFramer.Options(definition: MySQLServerTLSFramer.definition)
        options["tls"] = try ProxyTestTLS.server()
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in Task { @MainActor in
            if case .ready = state { self?.ready?.resume(); self?.ready = nil }
            if case .failed(let error) = state { self?.ready?.resume(throwing: error); self?.ready = nil }
        } }
        listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in await self?.serve(connection) } }
        try await withCheckedThrowingContinuation { ready = $0; listener.start(queue: .main) }
    }
    func stop() { listener?.cancel(); for socket in sockets { socket.close() } }

    private func serve(_ connection: NWConnection) async {
        let socket = PostgreSQLSocket(connection)
        sockets.append(socket)
        defer { socket.close(); closedConnectionCount += 1 }
        do {
            try await socket.start()
            let payload = try await MySQLWire.read(socket, sequence: 2)
            receivedHandshake = true
            var cursor = MySQLWire.Cursor(payload)
            _ = try cursor.take(32)
            #expect(try cursor.string() == "app_user")
            initialResponseWasEmpty = try cursor.lengthEncoded().isEmpty
            let challenge = scenario == "wrongPlugin"
                ? Data("mysql_native_password\0".utf8) + Data(1...20) + Data([0])
                : Data("mysql_clear_password\0".utf8)
            try await socket.send(MySQLWire.packet(Data([254]) + challenge, sequence: scenario == "wrongSequence" ? 7 : 3))
            let password = try await MySQLWire.read(socket, sequence: 4)
            let token = String(decoding: password.dropLast(), as: UTF8.self)
            if password.last == 0, token.contains("Action=connect"), token.contains("X-Amz-Signature="), token.contains("DBUser=app_user") {
                signedTokenCount += 1
            }
            let result = scenario == "rejectedToken"
                ? Data([255]) + MySQLWire.integer(1045, bytes: 2) + Data("#28000synthetic private error\0".utf8)
                : Data([0, 0, 0, 2, 0, 0, 0])
            try await socket.send(MySQLWire.packet(result, sequence: 5))
            while let data = try await socket.chunk() { try await socket.send(data) }
        } catch { /* Connection termination and TLS rejection are expected in these fixtures. */ }
    }
}
