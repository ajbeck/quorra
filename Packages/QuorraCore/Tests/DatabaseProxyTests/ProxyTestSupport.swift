import CryptoKit
import Foundation
import Network
import Security
import Testing
@testable import DatabaseProxy
import IAMIdentityCenter

@MainActor
final class ProxyCredentialFixture {
    let binding = DatabaseRoleBinding(sessionName: "Synthetic test", accountID: "123456789012", roleName: "Developer", region: "eu-west-2")
    let credentialID = UUID()
    let service = StubRoleCredentials()

    init() async throws {}

    func configuration(upstreamPort: Int, localPort: Int, authentication: LocalAuthentication = .trustLoopback) -> DatabaseConnectionSummary {
        .init(id: UUID(), draft: .init(name: "Synthetic proxy", host: "127.0.0.1", upstreamPort: upstreamPort,
             localPort: localPort, database: "app", username: "app_user", region: "eu-west-2", sessionName: binding.sessionName,
             accountID: binding.accountID, roleName: binding.roleName, localAuthentication: authentication),
              credentialID: credentialID, sessionName: binding.sessionName)
    }
}

/// Stands in for `IdentityCenterService.liveCredentials`. Clearing `credentials` behaves like
/// a session that can no longer mint.
nonisolated final class StubRoleCredentials: DatabaseRoleCredentialProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var current: RoleCredentials? = RoleCredentials(
        accessKeyId: "SYNTHETICACCESSKEY", secretAccessKey: "synthetic-secret-used-only-by-tests",
        sessionToken: "synthetic-session-token", expiresAt: .now.addingTimeInterval(3600), accountId: "123456789012",
        roleName: "Developer", region: "eu-west-2", sessionName: "Synthetic test", issuedAt: .now)

    func revoke() { lock.withLock { current = nil } }

    func credentials(for binding: DatabaseRoleBinding) async throws -> RoleCredentials {
        guard let credentials = lock.withLock({ current }) else { throw IAMIdentityCenterError.notSignedIn }
        return credentials
    }
}

nonisolated enum ProxyTestTLS {
    static func fixture(_ name: String, extension ext: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext))
        return try Data(contentsOf: url)
    }

    static func client(hostname: String = "127.0.0.1") throws -> NWProtocolTLS.Options {
        let root = try fixture("proxy-test-root", extension: "der")
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, hostname)
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
            let reference = sec_trust_copy_ref(trust).takeRetainedValue()
            SecTrustSetVerifyDate(reference, Date(timeIntervalSince1970: 1_790_035_200) as CFDate)
            complete(DatabaseServerTrust.evaluate(reference, hostname: hostname, roots: [root]))
        }, DispatchQueue(label: "dev.ajbeck.quorra.tests.trust"))
        return options
    }

    static func server() throws -> NWProtocolTLS.Options {
        let data = try fixture("proxy-test-server", extension: "p12")
        let importOptions = [kSecImportExportPassphrase as String: "duckblind-test-only", kSecImportToMemoryOnly as String: true] as [String: Any]
        var result: CFArray?
        let status = SecPKCS12Import(data as CFData, importOptions as CFDictionary, &result)
        #expect(status == errSecSuccess)
        let items = try #require(result as? [[String: Any]])
        let item = try #require(items.first?[kSecImportItemIdentity as String])
        let identity = item as! SecIdentity
        let local = try #require(sec_identity_create(identity))
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, local)
        return options
    }
}

/// Independent server-side TLS upgrade, used to exercise the production client
/// framer and SecTrust over real loopback sockets.
nonisolated final class ProxyTestServerFramer: NWProtocolFramerImplementation {
    static let label = "Synthetic PostgreSQL TLS server"
    static let definition = NWProtocolFramer.Definition(implementation: ProxyTestServerFramer.self)
    let tls: NWProtocolTLS.Options?
    init(framer: NWProtocolFramer.Instance) { tls = framer.options["tlsOptions"] as? NWProtocolTLS.Options }
    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .willMarkReady }
    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        var request: Data?
        _ = framer.parseInput(minimumIncompleteLength: 8, maximumLength: 8) { buffer, _ in
            guard let buffer, buffer.count >= 8 else { return 0 }
            request = Data(buffer); return 8
        }
        guard let request else { return 8 }
        guard request == PostgreSQLWire.integer(8) + PostgreSQLWire.integer(PostgreSQLWire.sslRequest), let tls else {
            framer.markFailed(error: .posix(.EPROTO)); return 0
        }
        framer.writeOutput(data: Data([83]))
        do { try framer.prependApplicationProtocol(options: tls) }
        catch { framer.markFailed(error: .posix(.EPROTO)); return 0 }
        framer.passThroughInput(); framer.passThroughOutput(); framer.markReady()
        return 0
    }
    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        try? framer.writeOutputNoCopy(length: messageLength)
    }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}
}

@MainActor
final class ProxyTestServer {
    private let acceptsTLS: Bool
    var rejectsLogin = false
    private var listener: NWListener?
    private var ready: CheckedContinuation<Void, any Error>?
    private var sockets: [UUID: PostgreSQLSocket] = [:]
    private(set) var passwordCount = 0
    private(set) var closedConnectionCount = 0
    private(set) var signedTokenCount = 0
    private(set) var cancellationCount = 0
    private(set) var startupParameters: [[String: String]] = []
    private(set) var bytesAfterTLSRefusal = 0
    let backendKey = Data([0, 0, 0, 17, 0, 0, 0, 29])
    var port: Int { Int(listener?.port?.rawValue ?? 0) }

    init(acceptsTLS: Bool = true) { self.acceptsTLS = acceptsTLS }

    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        if acceptsTLS {
            let framer = NWProtocolFramer.Options(definition: ProxyTestServerFramer.definition)
            framer["tlsOptions"] = try ProxyTestTLS.server()
            parameters.defaultProtocolStack.applicationProtocols.insert(framer, at: 0)
        }
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                if case .ready = state { self.ready?.resume(); self.ready = nil }
                if case .failed(let error) = state { self.ready?.resume(throwing: error); self.ready = nil }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in await self?.serve(connection) } }
        try await withCheckedThrowingContinuation { ready = $0; listener.start(queue: .main) }
    }

    func stop() { listener?.cancel(); for socket in sockets.values { socket.close() }; sockets.removeAll() }

    private func serve(_ connection: NWConnection) async {
        let id = UUID(), socket = PostgreSQLSocket(connection)
        sockets[id] = socket
        defer { socket.close(); sockets[id] = nil; closedConnectionCount += 1 }
        do {
            try await socket.start()
            let count = Int(try PostgreSQLWire.uint32(await socket.exact(4)))
            let body = try await socket.exact(count - 4)
            if !acceptsTLS {
                #expect(count == 8 && body == PostgreSQLWire.integer(PostgreSQLWire.sslRequest))
                try await socket.send(Data([78]))
                while let data = try await socket.chunk() { bytesAfterTLSRefusal += data.count }
                return
            }
            if try PostgreSQLWire.uint32(Data(body.prefix(4))) == PostgreSQLWire.cancelRequest {
                if Data(body.dropFirst(4)) == backendKey { cancellationCount += 1 }
                return
            }
            startupParameters.append(try PostgreSQLWire.parameters(Data(body.dropFirst(4))))
            try await socket.send(PostgreSQLWire.authentication(3))
            let password = try await socket.message()
            guard password.type == 112, let value = String(data: password.body.dropLast(), encoding: .utf8) else { return }
            passwordCount += 1
            if value.contains("Action=connect"), value.contains("X-Amz-Signature="), value.contains("DBUser=app_user") { signedTokenCount += 1 }
            if rejectsLogin {
                try await socket.send(PostgreSQLWire.error(ProxyError.upstreamAuthentication))
                return
            }
            try await socket.send(PostgreSQLWire.authentication(0))
            try await socket.send(PostgreSQLWire.message(83, Data("server_version\0".utf8) + Data("16.6\0".utf8)))
            try await socket.send(PostgreSQLWire.message(75, backendKey))
            try await socket.send(PostgreSQLWire.message(90, Data([73])))
            // Echo after authentication to verify raw relay fidelity/backpressure;
            // this synthetic server does not execute SQL.
            while let data = try await socket.chunk() { try await socket.send(data) }
        } catch { /* Expected when testing TLS rejection, cancellation, or stop. */ }
    }
}
