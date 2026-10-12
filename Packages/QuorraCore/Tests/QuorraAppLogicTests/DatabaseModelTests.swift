import DatabaseProxy
import Darwin
import Foundation
import IAMIdentityCenter
import SwiftData
import Testing
@testable import QuorraAppLogic

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct DatabaseModelTests {
    private let container: ModelContainer
    private let context: ModelContext
    private let secrets = DatabaseSecrets(keychain: InMemoryKeychainStore())

    init() throws {
        container = try QuorraMetadataSchema.makeContainer(inMemory: true)
        context = ModelContext(container)
    }

    private func makeModel() -> DatabaseModel {
        DatabaseModel(context: context, secrets: secrets) { session, account, role, region in
            RoleCredentials(accessKeyId: "SYNTHETICACCESSKEY", secretAccessKey: "synthetic-secret", sessionToken: "synthetic-token",
                            expiresAt: .now.addingTimeInterval(3600), accountId: account, roleName: role, region: region,
                            sessionName: session, issuedAt: .now)
        }
    }

    private func iamConnection(upstreamPort: Int) throws -> DatabaseConnectionDefinition {
        let session = SessionDefinition(name: "Work", startURL: "https://example.awsapps.com/start", region: "eu-west-2")
        context.insert(session)
        let profile = ProfileDefinition(name: "dev", session: session, accountID: "123456789012", roleName: "Developer")
        context.insert(profile)
        let draft = DatabaseConnectionDraft(name: "Orders", host: "127.0.0.1", upstreamPort: upstreamPort, localPort: try unusedPort(),
                                            database: "orders", username: "app_user", region: "eu-west-2")
        return try DatabaseStore.saveConnection(nil, draft: draft, profile: profile, credential: nil, clientVPN: nil, in: context)
    }

    @Test func unreachableUpstreamFailsStartAndIsLogged() async throws {
        let model = makeModel()
        let connection = try iamConnection(upstreamPort: try unusedPort())
        await #expect(throws: ProxyError.upstreamUnavailable) { try await model.start(connection) }
        let status = model.status(for: connection.stableID)
        #expect(status.state == .failed)
        #expect(status.issue?.contains("could not be reached") == true)
        #expect(model.hasFailure)
        #expect(!model.isActive(connection.stableID))

        try await waitForLog(model) { $0.contains { $0.event == "endpointFailed" } }
        let entries = try context.fetch(FetchDescriptor<DatabaseConnectionLogEntry>(sortBy: [SortDescriptor(\.timestamp)]))
        #expect(entries.allSatisfy { $0.connectionIDString == connection.stableIDString })
        #expect(entries.first?.event == "endpointStarting")
        #expect(entries.contains { $0.event == "endpointFailed" && $0.failureCode == "proxy.upstreamUnavailable" })

        try DatabaseConnectionLogStore.deleteAll(connectionID: connection.stableID, in: context)
        #expect(try context.fetchCount(FetchDescriptor<DatabaseConnectionLogEntry>()) == 0)
    }

    @Test func aNetworkThatCannotBeReadiedStopsStartAndTestBeforeTheUpstream() async throws {
        struct Refused: Error, Equatable {}
        var prepared: [String] = []
        let model = DatabaseModel(context: context, secrets: secrets, prepareNetwork: { connection in
            prepared.append(connection.name)
            throw Refused()
        }) { _, _, _, _ in throw Refused() }
        let connection = try iamConnection(upstreamPort: try unusedPort())
        await #expect(throws: Refused()) { try await model.start(connection) }
        await #expect(throws: Refused()) { try await model.test(connection) }
        #expect(prepared == ["Orders", "Orders"])
        #expect(model.status(for: connection.stableID).state == .stopped)
        #expect(model.workingConnectionIDs.isEmpty)
    }

    @Test func passwordConnectionWithoutAStoredPasswordFailsTest() async throws {
        let model = makeModel()
        let credential = DatabaseCredentialDefinition(name: "Login", username: "user")
        context.insert(credential)
        let draft = DatabaseConnectionDraft(name: "Local", host: "127.0.0.1", upstreamPort: try unusedPort(), localPort: try unusedPort(),
                                            database: "app", trust: .system, authentication: .databasePassword, tlsMode: .disabled)
        let connection = try DatabaseStore.saveConnection(nil, draft: draft, profile: nil, credential: credential, clientVPN: nil, in: context)
        await #expect(throws: ConfigurationError.missingCredential) { try await model.test(connection) }
        #expect(model.workingConnectionIDs.isEmpty)
    }

    private func waitForLog(_ model: DatabaseModel, until condition: ([DatabaseConnectionLogEntry]) -> Bool) async throws {
        for _ in 0..<200 {
            model.flushLog()
            if condition(try context.fetch(FetchDescriptor<DatabaseConnectionLogEntry>())) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The expected log entries were not recorded")
    }

    private func unusedPort() throws -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(bound == 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        try #require(named == 0)
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
