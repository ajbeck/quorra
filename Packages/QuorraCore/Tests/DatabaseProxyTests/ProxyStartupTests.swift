import Darwin
import Foundation
import Network
import Testing
@testable import DatabaseProxy

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ProxyStartupTests {
    @Test(arguments: [DatabaseEngine.postgresql, .mysql])
    func unreachableUpstreamFailsBeforeAnyLocalClient(engine: DatabaseEngine) async throws {
        let fixture = try await ProxyCredentialFixture()
        let directory = FileManager.default.temporaryDirectory.appending(path: "StartupLogs-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = DiagnosticLog(directory: directory, mirrorsToSystemLog: false)
        let proxy = makeProxy(fixture, diagnostics: diagnostics)
        let configuration = try configuration(fixture, engine: engine, port: unusedPort())
        await #expect(throws: ProxyError.upstreamUnavailable) {
            try await proxy.start(configuration, binding: fixture.binding, password: nil)
        }
        try await expectFailed(proxy, configuration, fixture: fixture, message: "could not be reached")
        let entries = try await diagnostics.recentEntries()
        #expect(entries.contains { $0.event == .endpointCheckingUpstream && $0.connectionID == configuration.id })
        #expect(entries.contains { $0.event == .endpointFailed && $0.failure?.code == "proxy.upstreamUnavailable" })
        #expect(!entries.contains { $0.event == .endpointListening || $0.event == .endpointUpstreamVerified })
    }

    @Test(arguments: [DatabaseEngine.postgresql, .mysql])
    func TLSFailureIsVisibleBeforeAnyLocalClient(engine: DatabaseEngine) async throws {
        let fixture = try await ProxyCredentialFixture()
        let postgres = ProxyTestServer(), mysql = MySQLIAMServer()
        try await postgres.start(); try await mysql.start()
        defer { postgres.stop(); mysql.stop() }
        let proxy = makeProxy(fixture, hostname: "wrong.example.test")
        let configuration = try configuration(fixture, engine: engine, port: engine == .mysql ? mysql.port : postgres.port)
        await #expect(throws: ProxyError.upstreamTLS) {
            try await proxy.start(configuration, binding: fixture.binding, password: nil)
        }
        try await expectFailed(proxy, configuration, fixture: fixture, message: "TLS")
        #expect(postgres.passwordCount == 0)
        #expect(mysql.signedTokenCount == 0)
    }

    @Test(arguments: [DatabaseEngine.postgresql, .mysql], [CredentialKind.awsIAM, .databasePassword])
    func rejectedLoginFailsAtStart(engine: DatabaseEngine, authentication: CredentialKind) async throws {
        let fixture = try await ProxyCredentialFixture()
        let postgres = ProxyTestServer(), mysql = MySQLIAMServer(scenario: "rejectedToken")
        postgres.rejectsLogin = true
        try await postgres.start(); try await mysql.start()
        defer { postgres.stop(); mysql.stop() }
        let proxy = makeProxy(fixture)
        let configuration = try configuration(fixture, engine: engine, port: engine == .mysql ? mysql.port : postgres.port,
                                              authentication: authentication)
        let expected: ProxyError = authentication == .awsIAM ? .upstreamAuthentication : .upstreamPasswordAuthentication
        await #expect(throws: expected) {
            try await proxy.start(configuration, binding: authentication == .awsIAM ? fixture.binding : nil, password: nil)
        }
        try await expectFailed(proxy, configuration, fixture: fixture, message: authentication == .awsIAM ? "IAM" : "password")
    }

    @Test(arguments: [DatabaseEngine.postgresql, .mysql], [CredentialKind.awsIAM, .databasePassword])
    func successfulCheckOpensListenerWithNoLocalClients(engine: DatabaseEngine, authentication: CredentialKind) async throws {
        let fixture = try await ProxyCredentialFixture()
        let postgres = ProxyTestServer(), mysql = MySQLIAMServer()
        try await postgres.start(); try await mysql.start()
        defer { postgres.stop(); mysql.stop() }
        let proxy = makeProxy(fixture)
        let configuration = try configuration(fixture, engine: engine, port: engine == .mysql ? mysql.port : postgres.port,
                                              authentication: authentication)
        try await proxy.start(configuration, binding: authentication == .awsIAM ? fixture.binding : nil, password: nil)
        #expect(proxy.statuses[configuration.id]?.state == .listening)
        #expect(proxy.statuses[configuration.id]?.activeConnections == 0)
        #expect(engine == .mysql ? mysql.receivedHandshake : postgres.passwordCount == 1)
        try await waitUntil { engine == .mysql ? mysql.closedConnectionCount == 1 : postgres.closedConnectionCount == 1 }
        await proxy.stop(configuration.id)
    }

    @Test func failedStartCanBeRetriedAfterUpstreamRecovers() async throws {
        let fixture = try await ProxyCredentialFixture()
        let server = ProxyTestServer()
        server.rejectsLogin = true
        try await server.start()
        defer { server.stop() }
        let proxy = makeProxy(fixture)
        let configuration = try configuration(fixture, engine: .postgresql, port: server.port)
        await #expect(throws: ProxyError.upstreamAuthentication) {
            try await proxy.start(configuration, binding: fixture.binding, password: nil)
        }
        server.rejectsLogin = false
        try await proxy.start(configuration, binding: fixture.binding, password: nil)
        #expect(proxy.statuses[configuration.id]?.state == .listening)
        #expect(proxy.statuses[configuration.id]?.issue == nil)
        #expect(server.passwordCount == 2)
        await proxy.stop(configuration.id)
    }

    @Test(arguments: [DatabaseEngine.postgresql, .mysql])
    func silentUpstreamTimesOutAndReleasesStartup(engine: DatabaseEngine) async throws {
        let fixture = try await ProxyCredentialFixture()
        let connector = SilentStartupConnector()
        let proxy = ProxyCoordinator(credentials: fixture.service, upstream: connector, mysql: connector,
                                     upstreamCheckTimeout: .milliseconds(100))
        let configuration = try configuration(fixture, engine: engine, port: 5432)
        await #expect(throws: ProxyError.timedOut) {
            try await proxy.start(configuration, binding: fixture.binding, password: nil)
        }
        try await expectFailed(proxy, configuration, fixture: fixture, message: "timed out")
        #expect(await connector.cancelled)
    }

    @Test(arguments: ["stop", "cancel", "shutdown"])
    func pendingCheckIsCancelledWithoutStartingListener(action: String) async throws {
        let fixture = try await ProxyCredentialFixture()
        let connector = SilentStartupConnector()
        let proxy = ProxyCoordinator(credentials: fixture.service, upstream: connector)
        let configuration = try configuration(fixture, engine: .postgresql, port: 5432)
        let start = Task { try await proxy.start(configuration, binding: fixture.binding, password: nil) }
        try await waitUntil { await connector.started }
        #expect(proxy.statuses[configuration.id]?.state == .checkingUpstream)
        try expectPortFree(configuration.draft.localPort)
        switch action {
        case "stop": await proxy.stop(configuration.id)
        case "shutdown": await proxy.shutdown()
        default: start.cancel()
        }
        await #expect(throws: CancellationError.self) { try await start.value }
        #expect(await connector.cancelled)
        #expect(proxy.statuses[configuration.id]?.state == .stopped)
        #expect(!proxy.isActive(configuration.id))
        try expectPortFree(configuration.draft.localPort)
    }

    @Test func cancelledCheckCannotReplaceRestartedEndpoint() async throws {
        let fixture = try await ProxyCredentialFixture()
        let server = ProxyTestServer()
        try await server.start()
        defer { server.stop() }
        let connector = DelayedStartupConnector(upstream: PostgreSQLConnector(service: fixture.service,
                                                tlsOptions: { _, _ in try ProxyTestTLS.client() }))
        let proxy = ProxyCoordinator(credentials: fixture.service, upstream: connector)
        let configuration = try configuration(fixture, engine: .postgresql, port: server.port)
        let oldStart = Task { try await proxy.start(configuration, binding: fixture.binding, password: nil) }
        try await waitUntil { await connector.pending }
        await proxy.stop(configuration.id)
        try await proxy.start(configuration, binding: fixture.binding, password: nil)
        await connector.release()
        await #expect(throws: CancellationError.self) { try await oldStart.value }
        #expect(proxy.statuses[configuration.id]?.state == .listening)
        #expect(proxy.statuses[configuration.id]?.issue == nil)
        #expect(proxy.isActive(configuration.id))
        await proxy.stop(configuration.id)
    }

    private func makeProxy(_ fixture: ProxyCredentialFixture, hostname: String = "127.0.0.1",
                           diagnostics: DiagnosticLog = .disabled) -> ProxyCoordinator {
        ProxyCoordinator(credentials: fixture.service,
            upstream: PostgreSQLConnector(service: fixture.service, passwordLogin: { _ in .init(username: "app_user", password: "synthetic") },
                                          tlsOptions: { _, _ in try ProxyTestTLS.client(hostname: hostname) }),
            mysql: MySQLConnector(service: fixture.service, passwordLogin: { _ in .init(username: "app_user", password: "synthetic") },
                                  tlsOptions: { _, _ in try ProxyTestTLS.client(hostname: hostname) }), diagnostics: diagnostics)
    }

    private func configuration(_ fixture: ProxyCredentialFixture, engine: DatabaseEngine, port: Int,
                               authentication: CredentialKind = .awsIAM) throws -> DatabaseConnectionSummary {
        var draft = fixture.configuration(upstreamPort: port, localPort: try unusedPort()).draft
        draft.engine = engine
        draft.authentication = authentication
        if authentication == .databasePassword { draft.passwordCredentialID = fixture.credentialID }
        return .init(id: UUID(), draft: draft, credentialID: fixture.credentialID, sessionName: "Synthetic")
    }

    private func expectFailed(_ proxy: ProxyCoordinator, _ configuration: DatabaseConnectionSummary,
                              fixture: ProxyCredentialFixture, message: String) async throws {
        #expect(proxy.statuses[configuration.id]?.state == .failed)
        #expect(proxy.statuses[configuration.id]?.issue?.contains("Upstream check failed:") == true)
        #expect(proxy.statuses[configuration.id]?.issue?.contains(message) == true)
        #expect(proxy.statuses[configuration.id]?.activeConnections == 0)
        #expect(!proxy.isActive(configuration.id))
        try expectPortFree(configuration.draft.localPort)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Startup did not reach the expected stage")
        throw ProxyError.timedOut
    }

    private func unusedPort() throws -> Int { try boundPort(0) }
    private func expectPortFree(_ port: Int) throws { #expect(try boundPort(port) == port) }
    private func boundPort(_ port: Int) throws -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = UInt16(port).bigEndian
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

private actor SilentStartupConnector: PostgreSQLUpstreamConnecting, MySQLUpstreamConnecting {
    private(set) var started = false
    private(set) var cancelled = false
    private func wait() async throws {
        started = true
        do { try await Task.sleep(for: .seconds(3600)) }
        catch { cancelled = true; throw error }
    }
    func connect(configuration: DatabaseConnectionSummary, binding: DatabaseRoleBinding?, parameters: [String: String]) async throws -> PostgreSQLUpstreamSession {
        try await wait(); throw ProxyError.timedOut
    }
    func connect(configuration: DatabaseConnectionSummary, binding: DatabaseRoleBinding?, capabilities: UInt32, characterSet: UInt8, attributes: Data) async throws -> MySQLUpstreamSession {
        try await wait(); throw ProxyError.timedOut
    }
    func cancel(configuration: DatabaseConnectionSummary, backendKey: Data) async throws {}
}

/// Delays an already-authenticated result, deliberately ignoring cancellation,
/// to exercise the coordinator's defense against completion after a restart.
private actor DelayedStartupConnector: PostgreSQLUpstreamConnecting {
    let upstream: PostgreSQLConnector
    private var continuation: CheckedContinuation<Void, Never>?
    private var first = true
    var pending: Bool { continuation != nil }
    init(upstream: PostgreSQLConnector) { self.upstream = upstream }
    func release() { continuation?.resume(); continuation = nil }
    func connect(configuration: DatabaseConnectionSummary, binding: DatabaseRoleBinding?, parameters: [String: String]) async throws -> PostgreSQLUpstreamSession {
        let session = try await upstream.connect(configuration: configuration, binding: binding, parameters: parameters)
        if first {
            first = false
            await withCheckedContinuation { continuation = $0 }
        }
        return session
    }
    func cancel(configuration: DatabaseConnectionSummary, backendKey: Data) async throws {}
}
