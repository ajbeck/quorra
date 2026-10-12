import CommonCrypto
import CryptoKit
import Darwin
import Foundation
import Network
import Testing
@testable import DatabaseProxy

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ProxyIntegrationTests {
    @Test func loopbackToVerifiedTLSUsesIAMAndRelaysLargeMessagesAndCancellation() async throws {
        let logDirectory = FileManager.default.temporaryDirectory.appending(path: "ProxyLogs-\(UUID())")
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        let diagnostics = DiagnosticLog(directory: logDirectory, mirrorsToSystemLog: false)
        let f = try await ProxyCredentialFixture()
        let server = ProxyTestServer()
        try await server.start()
        defer { server.stop() }
        let connector = PostgreSQLConnector(service: f.service, diagnostics: diagnostics, tlsOptions: { _, _ in try ProxyTestTLS.client() })
        let proxy = ProxyCoordinator(credentials: f.service, upstream: connector, diagnostics: diagnostics)
        let configuration = f.configuration(upstreamPort: server.port, localPort: try unusedPort())
        try await proxy.start(configuration, binding: f.binding, password: nil)
        #expect(server.passwordCount == 1)
        #expect(server.startupParameters.first?["application_name"] == "Quorra connection test")
        #expect(proxy.statuses[configuration.id]?.activeConnections == 0)
        let client = try await localClient(configuration)
        defer { client.close() }
        try await client.send(PostgreSQLWire.integer(8) + PostgreSQLWire.integer(PostgreSQLWire.sslRequest))
        #expect(try await client.exact(1) == Data([78]))
        var startup = PostgreSQLWire.startup(["user": "quorra", "database": "app", "application_name": "proxy-integration"])
        startup.replaceSubrange(4..<8, with: PostgreSQLWire.integer(196610)) // Modern client, protocol 3.2.
        try await client.send(startup)
        let version = try await client.message()
        #expect(version.type == 118)
        #expect(version.body == PostgreSQLWire.integer(0) + PostgreSQLWire.integer(0))
        let key = try await ready(client)
        #expect(key != server.backendKey)
        #expect(server.startupParameters.first?["user"] == "app_user")
        #expect(server.passwordCount == 2)
        #expect(server.signedTokenCount == 2)
        #expect(server.startupParameters.last?["application_name"] == "proxy-integration")
        let invalidCancel = try await localClient(configuration)
        var invalidKey = key
        invalidKey[invalidKey.startIndex] ^= 0x80
        try await invalidCancel.send(PostgreSQLWire.integer(16) + PostgreSQLWire.integer(PostgreSQLWire.cancelRequest) + invalidKey)
        #expect(try await invalidCancel.chunk(maximum: 1) == nil)
        invalidCancel.close()
        #expect(server.cancellationCount == 0)
        let payload = Data((0..<800_000).map { UInt8($0 % 251) })
        async let sending: Void = client.send(payload)
        #expect(try await client.exact(payload.count) == payload)
        try await sending
        let cancel = try await localClient(configuration)
        try await cancel.send(PostgreSQLWire.integer(16) + PostgreSQLWire.integer(PostgreSQLWire.cancelRequest) + key)
        #expect(try await cancel.chunk(maximum: 1) == nil)
        cancel.close()
        #expect(server.cancellationCount == 1)
        #expect(proxy.statuses[configuration.id]?.activeConnections == 1)
        await proxy.stop(configuration.id)
        #expect(proxy.statuses[configuration.id]?.activeConnections == 0)
        #expect(!proxy.isActive(configuration.id))
        let entries = try await diagnostics.recentEntries()
        let events = Set(entries.map(\.event))
        #expect(events.isSuperset(of: [.endpointListening, .clientAuthenticated, .upstreamAuthenticated,
                                      .cancellationForwarded, .endpointStopped]))
        let verified = try #require(entries.firstIndex { $0.event == .endpointUpstreamVerified })
        let listening = try #require(entries.firstIndex { $0.event == .endpointListening })
        #expect(verified < listening)
        #expect(entries.filter { $0.category == "proxy" }.allSatisfy { $0.connectionID == configuration.id })
        let raw = try String(contentsOf: logDirectory.appending(path: "database-proxy.jsonl"), encoding: .utf8)
        for value in ["SYNTHETICACCESSKEY", "synthetic-session-token", "X-Amz-Signature", "app_user", "proxy-integration"] {
            #expect(!raw.contains(value))
        }
    }

    @Test func generatedPasswordAcceptsIndependentSCRAMClientAndRejectsBadPasswordBeforeAWS() async throws {
        let f = try await ProxyCredentialFixture()
        let server = ProxyTestServer()
        try await server.start()
        defer { server.stop() }
        let proxy = ProxyCoordinator(credentials: f.service,
            upstream: PostgreSQLConnector(service: f.service, tlsOptions: { _, _ in try ProxyTestTLS.client() }))
        let configuration = f.configuration(upstreamPort: server.port, localPort: try unusedPort(), authentication: .generatedPassword)
        try await proxy.start(configuration, binding: f.binding, password: "synthetic-local-password")
        let wrongUser = try await localClient(configuration)
        try await wrongUser.send(PostgreSQLWire.startup(["user": "app_user", "database": "app"]))
        #expect(try await wrongUser.message().type == 69)
        wrongUser.close()
        #expect(server.passwordCount == 1) // Startup check only; no login for the rejected client.
        let wrong = try await localClient(configuration)
        defer { wrong.close() }
        try await wrong.send(PostgreSQLWire.startup(["user": "quorra", "database": "app"]))
        let rejected = try await scramClient(wrong, password: "wrong-password")
        #expect(rejected.type == 69)
        #expect(server.passwordCount == 1)
        let client = try await localClient(configuration)
        defer { client.close() }
        try await client.send(PostgreSQLWire.startup(["user": "quorra", "database": "app"]))
        let final = try await scramClient(client, password: "synthetic-local-password")
        #expect(final.type == 82)
        #expect(try PostgreSQLWire.uint32(Data(final.body.prefix(4))) == 12)
        _ = try await ready(client)
        #expect(server.startupParameters.first?["user"] == "app_user")
        #expect(server.passwordCount == 2)
        #expect(server.signedTokenCount == 2)
        await proxy.stop(configuration.id)
    }

    @Test func wrongUpstreamHostnameFailsTLSBeforeSendingIAMPassword() async throws {
        let f = try await ProxyCredentialFixture()
        let server = ProxyTestServer()
        try await server.start()
        defer { server.stop() }
        let connector = PostgreSQLConnector(service: f.service, tlsOptions: { _, _ in try ProxyTestTLS.client(hostname: "wrong.example.test") })
        let configuration = f.configuration(upstreamPort: server.port, localPort: try unusedPort())
        await #expect(throws: ProxyError.upstreamTLS) {
            _ = try await connector.connect(configuration: configuration, binding: f.binding, parameters: [:])
        }
        #expect(server.passwordCount == 0)
    }

    @Test func occupiedPortFailsAndDoesNotLeaveActiveCredentialBinding() async throws {
        let f = try await ProxyCredentialFixture()
        let occupied = ProxyTestServer()
        try await occupied.start()
        defer { occupied.stop() }
        let proxy = ProxyCoordinator(credentials: f.service,
            upstream: PostgreSQLConnector(service: f.service, tlsOptions: { _, _ in try ProxyTestTLS.client() }))
        let configuration = f.configuration(upstreamPort: occupied.port, localPort: occupied.port)
        await #expect(throws: ProxyError.portInUse) { try await proxy.start(configuration, binding: f.binding, password: nil) }
        #expect(proxy.statuses[configuration.id]?.state == .failed)
        #expect(proxy.statuses[configuration.id]?.issue == ProxyError.portInUse.localizedDescription)
        #expect(!proxy.isActive(configuration.id))
    }

    @Test(arguments: [DatabaseEngine.postgresql, .mysql])
    func stopClosesIncompleteHandshakeAndAllowsExplicitRestart(engine: DatabaseEngine) async throws {
        let f = try await ProxyCredentialFixture()
        let postgres = ProxyTestServer(), mysql = MySQLIAMServer()
        try await postgres.start()
        try await mysql.start()
        defer { postgres.stop(); mysql.stop() }
        let proxy = ProxyCoordinator(credentials: f.service,
            upstream: PostgreSQLConnector(service: f.service, tlsOptions: { _, _ in try ProxyTestTLS.client() }),
            mysql: MySQLConnector(service: f.service, tlsOptions: { _, _ in try ProxyTestTLS.client() }))
        var draft = f.configuration(upstreamPort: engine == .mysql ? mysql.port : postgres.port, localPort: try unusedPort()).draft
        draft.engine = engine
        let configuration = DatabaseConnectionSummary(id: UUID(), draft: draft, credentialID: f.credentialID, sessionName: "Synthetic")
        try await proxy.start(configuration, binding: f.binding, password: nil)
        let pending = try await localClient(configuration)
        defer { pending.close() }
        if engine == .mysql {
            _ = try await MySQLWire.read(pending, sequence: 0)
        } else {
            try await pending.send(PostgreSQLWire.integer(8) + PostgreSQLWire.integer(PostgreSQLWire.sslRequest))
            #expect(try await pending.exact(1) == Data([78]))
        }
        await proxy.stop(configuration.id)
        #expect(try await pending.chunk() == nil)
        #expect(proxy.statuses[configuration.id]?.state == .stopped)
        try await proxy.start(configuration, binding: f.binding, password: nil)
        #expect(proxy.statuses[configuration.id]?.state == .listening)
        await proxy.shutdown()
        #expect(!proxy.isActive(configuration.id))
        await #expect(throws: ProxyError.stopped) { try await proxy.start(configuration, binding: f.binding, password: nil) }
    }

    @Test func upstreamTLSRefusalNeverFallsBackToPlaintext() async throws {
        let f = try await ProxyCredentialFixture()
        let server = ProxyTestServer(acceptsTLS: false)
        try await server.start()
        defer { server.stop() }
        let connector = PostgreSQLConnector(service: f.service, tlsOptions: { _, _ in try ProxyTestTLS.client() })
        let configuration = f.configuration(upstreamPort: server.port, localPort: try unusedPort())
        await #expect(throws: ProxyError.upstreamTLS) {
            _ = try await connector.connect(configuration: configuration, binding: f.binding, parameters: [:])
        }
        #expect(server.passwordCount == 0)
        #expect(server.bytesAfterTLSRefusal == 0)
    }

    @Test func expiredCredentialsBlockNewLoginsWithoutClosingEstablishedSession() async throws {
        let f = try await ProxyCredentialFixture()
        let server = ProxyTestServer()
        try await server.start()
        defer { server.stop() }
        let proxy = ProxyCoordinator(credentials: f.service,
            upstream: PostgreSQLConnector(service: f.service, tlsOptions: { _, _ in try ProxyTestTLS.client() }))
        let configuration = f.configuration(upstreamPort: server.port, localPort: try unusedPort())
        try await proxy.start(configuration, binding: f.binding, password: nil)
        let established = try await localClient(configuration)
        defer { established.close() }
        try await established.send(PostgreSQLWire.startup(["user": "quorra", "database": "app"]))
        _ = try await ready(established)
        f.service.revoke()
        let newClient = try await localClient(configuration)
        defer { newClient.close() }
        try await newClient.send(PostgreSQLWire.startup(["user": "quorra", "database": "app"]))
        #expect(try await newClient.message().type == 69)
        let payload = Data("synthetic existing session remains usable".utf8)
        try await established.send(payload)
        #expect(try await established.exact(payload.count) == payload)
        #expect(server.passwordCount == 2)
        #expect(proxy.statuses[configuration.id]?.state == .listening)
        await proxy.stop(configuration.id)
    }

    @Test func rdsProxyTrustRejectsUntrustedServerBeforeSendingIAMToken() async throws {
        let f = try await ProxyCredentialFixture()
        let server = ProxyTestServer()
        try await server.start()
        defer { server.stop() }
        let original = f.configuration(upstreamPort: server.port, localPort: try unusedPort())
        var draft = original.draft
        draft.trust = .rdsProxy
        let configuration = DatabaseConnectionSummary(id: original.id, draft: draft, credentialID: original.credentialID, sessionName: original.sessionName)
        let connector = PostgreSQLConnector(service: f.service)
        await #expect(throws: ProxyError.upstreamTLS) {
            _ = try await connector.connect(configuration: configuration, binding: f.binding, parameters: [:])
        }
        #expect(server.passwordCount == 0)
    }

    private func localClient(_ configuration: DatabaseConnectionSummary) async throws -> PostgreSQLSocket {
        let socket = PostgreSQLSocket(NWConnection(host: .ipv4(.loopback), port: .init(rawValue: UInt16(configuration.draft.localPort))!, using: .tcp))
        try await socket.start()
        return socket
    }

    private func ready(_ socket: PostgreSQLSocket) async throws -> Data {
        var key = Data()
        for _ in 0..<16 {
            let message = try await socket.message()
            switch message.type {
            case 82: #expect(message.body == PostgreSQLWire.integer(0))
            case 83: break
            case 75: key = message.body
            case 90: #expect(message.body == Data([73])); return key
            default: throw ProxyError.malformedMessage
            }
        }
        throw ProxyError.malformedMessage
    }

    /// Uses CommonCrypto PBKDF2 as an independent client implementation. The
    /// server's implementation is separately checked against the RFC 7677 vector.
    private func scramClient(_ socket: PostgreSQLSocket, password: String) async throws -> (type: UInt8, body: Data) {
        let request = try await socket.message()
        #expect(request.type == 82)
        #expect(request.body == PostgreSQLWire.integer(10) + Data("SCRAM-SHA-256\0\0".utf8))
        let firstBare = "n=,r=syntheticClientNonce1234567890"
        let first = Data("n,,\(firstBare)".utf8)
        try await socket.send(PostgreSQLWire.message(112, Data("SCRAM-SHA-256\0".utf8) + PostgreSQLWire.integer(UInt32(first.count)) + first))
        let challenge = try await socket.message()
        #expect(challenge.type == 82)
        let serverFirst = try #require(String(data: challenge.body.dropFirst(4), encoding: .utf8))
        let values = Dictionary(uniqueKeysWithValues: serverFirst.split(separator: ",").map { (String($0.prefix(1)), String($0.dropFirst(2))) })
        let saltString = try #require(values["s"])
        let roundsString = try #require(values["i"])
        let salt = try #require(Data(base64Encoded: saltString))
        let rounds = try #require(UInt32(roundsString))
        let nonce = try #require(values["r"])
        var derived = [UInt8](repeating: 0, count: 32)
        let status = password.withCString { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes, password.utf8.count,
                                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &derived, 32)
            }
        }
        #expect(status == kCCSuccess)
        let key = SymmetricKey(data: derived)
        let clientKey = Data(HMAC<SHA256>.authenticationCode(for: Data("Client Key".utf8), using: key))
        let storedKey = SymmetricKey(data: Data(SHA256.hash(data: clientKey)))
        let finalBare = "c=biws,r=\(nonce)"
        let authentication = Data("\(firstBare),\(serverFirst),\(finalBare)".utf8)
        let signature = HMAC<SHA256>.authenticationCode(for: authentication, using: storedKey)
        let proof = Data(zip(clientKey, signature).map { $0 ^ $1 }).base64EncodedString()
        try await socket.send(PostgreSQLWire.message(112, Data("\(finalBare),p=\(proof)".utf8)))
        let final = try await socket.message()
        if final.type == 82 {
            let serverKey = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data("Server Key".utf8), using: key)))
            let signature = Data(HMAC<SHA256>.authenticationCode(for: authentication, using: serverKey)).base64EncodedString()
            #expect(String(data: final.body.dropFirst(4), encoding: .utf8) == "v=\(signature)")
        }
        return final
    }

    private func unusedPort() throws -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(result == 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let name = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        try #require(name == 0)
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
