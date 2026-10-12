import DatabaseProxy
import Foundation
import SwiftData
import Testing
@testable import QuorraAppLogic

@MainActor
struct DatabaseStoreTests {
    private let container: ModelContainer
    private let context: ModelContext
    private let keychain = InMemoryKeychainStore()
    private var secrets: DatabaseSecrets { DatabaseSecrets(keychain: keychain) }

    init() throws {
        container = try QuorraMetadataSchema.makeContainer(inMemory: true)
        context = ModelContext(container)
    }

    private func profile(named name: String = "dev", session sessionName: String? = "Work") -> ProfileDefinition {
        let session = sessionName.map { SessionDefinition(name: $0, startURL: "https://example.awsapps.com/start", region: "eu-west-2") }
        if let session { context.insert(session) }
        let profile = ProfileDefinition(name: name, session: session, accountID: "123456789012", roleName: "Developer")
        context.insert(profile)
        return profile
    }

    private func iamDraft(localPort: Int = 15432) -> DatabaseConnectionDraft {
        DatabaseConnectionDraft(name: "Orders", host: "orders.example.eu-west-2.rds.amazonaws.com", localPort: localPort,
                                database: "orders", username: "app_user", region: "EU-WEST-2")
    }

    private func passwordDraft(localPort: Int = 15433) -> DatabaseConnectionDraft {
        DatabaseConnectionDraft(name: "Password database", host: "localhost", localPort: localPort, database: "app",
                                trust: .system, authentication: .databasePassword)
    }

    @Test func iamConnectionTakesItsBindingFromTheProfile() throws {
        let profile = profile()
        let connection = try DatabaseStore.saveConnection(nil, draft: iamDraft(), profile: profile, credential: nil, in: context)
        let draft = connection.draft
        #expect(draft.sessionName == "Work")
        #expect(draft.accountID == "123456789012" && draft.roleName == "Developer")
        #expect(draft.region == "eu-west-2")
        #expect(draft.tlsMode == .verified && draft.localAuthentication == .generatedPassword)
        #expect(profile.databaseConnections.count == 1)
        let summary = DatabaseStore.summary(for: connection)
        #expect(summary.id == connection.stableID && summary.sessionName == "Work")
    }

    @Test func iamConnectionNeedsAProfileWithASession() throws {
        #expect(throws: ConfigurationError.missingSession) {
            try DatabaseStore.saveConnection(nil, draft: iamDraft(), profile: nil, credential: nil, in: context)
        }
        let unlinked = profile(named: "unlinked", session: nil)
        #expect(throws: ConfigurationError.missingSession) {
            try DatabaseStore.saveConnection(nil, draft: iamDraft(), profile: unlinked, credential: nil, in: context)
        }
        var disabled = iamDraft()
        disabled.tlsMode = .disabled
        #expect(throws: ConfigurationError.iamRequiresTLS) {
            try DatabaseStore.saveConnection(nil, draft: disabled, profile: profile(), credential: nil, in: context)
        }
    }

    @Test func localPortsAreUniqueButAnEditKeepsItsOwn() throws {
        let profile = profile()
        let first = try DatabaseStore.saveConnection(nil, draft: iamDraft(), profile: profile, credential: nil, in: context)
        #expect(throws: ConfigurationError.localPortInUse(15432)) {
            try DatabaseStore.saveConnection(nil, draft: iamDraft(), profile: profile, credential: nil, in: context)
        }
        var renamed = iamDraft()
        renamed.name = "Orders (read only)"
        try DatabaseStore.saveConnection(first, draft: renamed, profile: profile, credential: nil, in: context)
        #expect(try DatabaseStore.connections(in: context).map(\.name) == ["Orders (read only)"])
    }

    // Ported from Duck Blind's password-connection persistence test.
    @Test func passwordConnectionNeedsNoProfileAndKeepsItsLocalPasswordAcrossRotation() async throws {
        let credential = try await DatabaseStore.saveCredential(nil, name: "Development", username: "first_user",
                                                                password: "old-password", secrets: secrets, in: context)
        var draft = passwordDraft()
        let connection = try DatabaseStore.saveConnection(nil, draft: draft, profile: profile(), credential: credential, in: context)
        #expect(connection.profile == nil)
        #expect(connection.draft.tlsMode == .verified)
        #expect(connection.draft.passwordCredentialID == credential.stableID)
        let localPassword = try await secrets.localPassword(forConnection: connection.stableID)
        #expect(try await DatabaseStore.login(for: connection, secrets: secrets).password == "old-password")

        try await DatabaseStore.saveCredential(credential, name: "Development", username: "second_user",
                                               password: "new-password", secrets: secrets, in: context)
        let rotated = try await DatabaseStore.login(for: connection, secrets: secrets)
        #expect(rotated.username == "second_user" && rotated.password == "new-password")
        #expect(try await secrets.localPassword(forConnection: connection.stableID) == localPassword)
        let refusal = await #expect(throws: ConfigurationError.credentialInUse(["Password database"])) {
            try await DatabaseStore.deleteCredential(credential, secrets: secrets, in: context)
        }
        #expect(refusal?.localizedDescription == "Password database uses this credential. Choose another credential for it, then delete it.")

        draft.tlsMode = .disabled
        try DatabaseStore.saveConnection(connection, draft: draft, profile: nil, credential: credential, in: context)
        let reopened = try #require(try DatabaseStore.connection(id: connection.stableID, in: ModelContext(container)))
        #expect(reopened.draft.tlsMode == .disabled)
        #expect(reopened.draft.username == "second_user")
    }

    @Test func passwordConnectionNeedsACredentialAndANewCredentialNeedsAPassword() async throws {
        #expect(throws: ConfigurationError.missingCredential) {
            try DatabaseStore.saveConnection(nil, draft: passwordDraft(), profile: nil, credential: nil, in: context)
        }
        await #expect(throws: ConfigurationError.required("Password")) {
            _ = try await DatabaseStore.saveCredential(nil, name: "Login", username: "user", password: nil, secrets: secrets, in: context)
        }
        #expect(try DatabaseStore.credentials(in: context).isEmpty)
    }

    @Test func deletingRemovesTheKeychainItems() async throws {
        let credential = try await DatabaseStore.saveCredential(nil, name: "Login", username: "user", password: "secret",
                                                                secrets: secrets, in: context)
        let connection = try DatabaseStore.saveConnection(nil, draft: passwordDraft(), profile: nil, credential: credential, in: context)
        _ = try await secrets.localPassword(forConnection: connection.stableID)
        try await DatabaseStore.deleteConnection(connection, secrets: secrets, in: context)
        #expect(await keychain.enumerateAccounts(service: DatabaseSecrets.localPasswordService).isEmpty)
        try await DatabaseStore.deleteCredential(credential, secrets: secrets, in: context)
        #expect(await keychain.enumerateAccounts(service: DatabaseSecrets.passwordService).isEmpty)
        #expect(try DatabaseStore.connections(in: context).isEmpty && DatabaseStore.credentials(in: context).isEmpty)
    }

    @Test func importMatchesOnlyAUniqueProfileOrCredential() async throws {
        let iamFile = try ConnectionImport.decode(Data(#"{"version":1,"name":"Imported","engine":"postgresql","host":"db.example.test","database":"app","authentication":"awsIAM","username":"app_user","region":"eu-west-2","accountID":"123456789012","roleName":"Developer","sessionName":"Work"}"#.utf8))
        #expect(try DatabaseStore.importDraft(iamFile, in: context).profile == nil)
        let match = profile()
        #expect(try DatabaseStore.importDraft(iamFile, in: context).profile === match)
        let duplicate = ProfileDefinition(name: "dev-copy", session: match.session, accountID: "123456789012", roleName: "Developer")
        context.insert(duplicate)
        #expect(try DatabaseStore.importDraft(iamFile, in: context).profile == nil)

        let passwordFile = try ConnectionImport.decode(Data(#"{"version":1,"name":"Imported","engine":"mysql","host":"db.example.test","database":"app","authentication":"databasePassword","credentialName":"Database login"}"#.utf8))
        let credential = try await DatabaseStore.saveCredential(nil, name: "Database login", username: "user", password: "secret",
                                                                secrets: secrets, in: context)
        let imported = try DatabaseStore.importDraft(passwordFile, in: context)
        #expect(imported.credential === credential)
        #expect(imported.draft.localPort == DatabaseEngine.mysql.suggestedLocalPort)
        let saved = try DatabaseStore.saveConnection(nil, draft: imported.draft, profile: nil, credential: imported.credential, in: context)
        #expect(try DatabaseStore.importDraft(passwordFile, in: context).draft.localPort == saved.localPort + 1)
    }
}
