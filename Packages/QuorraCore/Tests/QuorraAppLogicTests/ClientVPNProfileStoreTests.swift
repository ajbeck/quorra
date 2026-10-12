import DatabaseProxy
import Foundation
import SwiftData
import Testing
@testable import QuorraAppLogic

@MainActor
struct ClientVPNProfileStoreTests {
    private let container: ModelContainer
    private let context: ModelContext
    private let secrets = ClientVPNProfileSecrets(keychain: InMemoryKeychainStore())
    private let text = "client\r\nremote vpn.example.com 443\r\nauth-federate\r\n<key>\r\nprivate\r\n</key>\r\n"

    init() throws {
        container = try QuorraMetadataSchema.makeContainer(inMemory: true)
        context = ModelContext(container)
    }

    private func add(name: String = " Work VPN ", endpoint: String = "vpn.example.com") async throws -> ClientVPNProfileDefinition {
        try await ClientVPNProfileStore.add(try ClientVPNProfile(text: text), fileName: "work.ovpn", name: name, endpoint: endpoint, secrets: secrets, in: context)
    }

    private func database(_ name: String, using vpn: ClientVPNProfileDefinition) {
        let draft = DatabaseConnectionDraft(name: name, host: "db.example.com", localPort: 15432, database: "app", trust: .system, authentication: .databasePassword)
        let connection = DatabaseConnectionDefinition(draft: draft, profile: nil, credential: nil)
        connection.clientVPN = vpn
        context.insert(connection)
    }

    @Test func addsAProfileWithTheTextInTheKeychain() async throws {
        let vpn = try await add()
        let reopened = try #require(try ClientVPNProfileStore.profile(id: vpn.stableID, in: ModelContext(container)))
        #expect(reopened.name == "Work VPN" && reopened.endpoint == "vpn.example.com" && reopened.fileName == "work.ovpn")
        #expect(reopened.port == 443 && reopened.transport == .udp && reopened.usesBrowserSignIn)
        #expect(try await ClientVPNProfileStore.connectionText(for: reopened, secrets: secrets) == text)
    }

    @Test func refusesANameOrEndpointItCannotUse() async throws {
        await #expect(throws: ClientVPNProfileError.missingName) { _ = try await add(name: "  ") }
        await #expect(throws: ClientVPNProfileError.invalidEndpoint) { _ = try await add(endpoint: "10.0.0.1") }
        #expect(try ClientVPNProfileStore.profiles(in: context).isEmpty)
    }

    @Test func connectsToTheChosenEndpoint() async throws {
        let vpn = try await add()
        try ClientVPNProfileStore.save(vpn, name: "Work", endpoint: " vpn.internal.example.com ", in: context)
        let connecting = try await ClientVPNProfileStore.connectionText(for: vpn, secrets: secrets)
        #expect(connecting == text.replacingOccurrences(of: "vpn.example.com", with: "vpn.internal.example.com"))
        #expect(vpn.name == "Work" && vpn.profileEndpoint == "vpn.example.com")
    }

    @Test(arguments: [("vpn.example.com", "new.example.com"), ("chosen.example.com", "chosen.example.com")])
    func replacingTheFileKeepsAChosenEndpoint(endpoint: String, expected: String) async throws {
        let vpn = try await add(endpoint: endpoint)
        let replacement = try ClientVPNProfile(text: "client\nremote new.example.com 1194\nproto tcp\n")
        try await ClientVPNProfileStore.replaceProfile(of: vpn, with: replacement, fileName: "new.ovpn", secrets: secrets, in: context)
        #expect(vpn.endpoint == expected && vpn.profileEndpoint == "new.example.com" && vpn.fileName == "new.ovpn")
        #expect(vpn.port == 1194 && vpn.transport == .tcp && !vpn.usesBrowserSignIn)
        #expect(try await ClientVPNProfileStore.connectionText(for: vpn, secrets: secrets).contains("remote \(expected) 1194"))
    }

    @Test func refusesDeletingAProfileInUseAndNamesTheDatabases() async throws {
        let vpn = try await add()
        database("reporting-pg", using: vpn)
        database("prod-pg", using: vpn)
        try context.save()
        let refusal = await #expect(throws: ClientVPNProfileError.inUse(["prod-pg", "reporting-pg"])) {
            try await ClientVPNProfileStore.delete(vpn, secrets: secrets, in: context)
        }
        #expect(refusal?.localizedDescription == "prod-pg and reporting-pg use this VPN. Choose another VPN for them, then delete it.")

        for connection in vpn.connections { connection.clientVPN = nil }
        let id = vpn.stableID
        try await ClientVPNProfileStore.delete(vpn, secrets: secrets, in: context)
        #expect(try ClientVPNProfileStore.profiles(in: context).isEmpty)
        await #expect(throws: ClientVPNProfileError.missingFromKeychain) { try await secrets.profile(for: id) }
    }
}
