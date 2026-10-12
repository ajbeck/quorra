import Foundation
import Testing
@testable import DatabaseProxy

@MainActor
struct ConnectionImportTests {
    private func data(engine: String = "postgresql", authentication: String = "awsIAM",
                      extra: [String: Any] = [:], removing: [String] = []) throws -> Data {
        var fields: [String: Any] = ["version": 1, "name": "Imported", "engine": engine,
                                   "host": "db.example.test", "database": "app", "authentication": authentication]
        if authentication == "awsIAM" {
            fields.merge(["username": "app_user", "region": "eu-west-2", "accountID": "123456789012",
                          "roleName": "Developer", "sessionName": "Work"]) { _, new in new }
        } else { fields["credentialName"] = "Database login" }
        fields.merge(extra) { _, new in new }
        for key in removing { fields[key] = nil }
        return try JSONSerialization.data(withJSONObject: fields)
    }

    @Test(arguments: [DatabaseEngine.postgresql, .mysql], [CredentialKind.awsIAM, .databasePassword])
    func importsEachEngineAndAuthenticationWithSecureDefaults(engine: DatabaseEngine, authentication: CredentialKind) throws {
        let document = try ConnectionImport.decode(data(engine: engine.rawValue, authentication: authentication.rawValue))
        let draft = try document.draft()
        #expect(draft.engine == engine)
        #expect(draft.authentication == authentication)
        #expect(draft.upstreamPort == engine.defaultPort)
        #expect(draft.localPort == engine.suggestedLocalPort)
        #expect(draft.tlsMode == .verified)
        #expect(draft.localAuthentication == .generatedPassword)
        #expect(draft.trust == (authentication == .awsIAM ? .rds : .system))
        #expect(draft.sessionName == (authentication == .awsIAM ? "Work" : nil))
        #expect(draft.passwordCredentialID == nil)
        #expect(draft.name == "Imported" && draft.host == "db.example.test" && draft.database == "app")
        try draft.validateSettings()
        if authentication == .databasePassword {
            #expect(throws: ConfigurationError.missingCredential) { try draft.connection(credentialID: UUID()) }
        }
    }

    @Test func preservesExplicitSettingsAndOnlySuggestsPortsWhenOmitted() throws {
        let document = try ConnectionImport.decode(data(extra: ["upstreamPort": 6432, "localPort": 25432,
                                                                "trust": "rdsProxy", "localAuthentication": "trustLoopback"]))
        let draft = try document.draft(usedLocalPorts: [25432])
        #expect(draft.upstreamPort == 6432 && draft.localPort == 25432)
        #expect(draft.trust == .rdsProxy && draft.localAuthentication == .trustLoopback)
        #expect(draft.username == "app_user" && draft.region == "eu-west-2")
        #expect(draft.accountID == "123456789012" && draft.roleName == "Developer")
        let defaults = try ConnectionImport.decode(data(engine: "mysql", authentication: "databasePassword"))
        #expect(try defaults.draft(usedLocalPorts: [13306, 13307]).localPort == 13308)
        #expect(try defaults.draft(usedLocalPorts: Set(13306...65535)).localPort == 1024)
        #expect(throws: ConnectionImportError.noAvailablePort) { try defaults.draft(usedLocalPorts: Set(1024...65535)) }
    }

    @Test(arguments: ["version", "name", "host", "database", "engine", "authentication"])
    func rejectsMissingRequiredFields(field: String) throws {
        #expect(throws: ConnectionImportError.invalidDocument) { try ConnectionImport.decode(data(removing: [field])) }
    }

    @Test func rejectsBadJSONVersionTypesAndUnknownFieldsWithoutEchoingContents() throws {
        for bytes in [Data(), Data("[]".utf8), Data("{secret contents".utf8)] {
            #expect(throws: ConnectionImportError.invalidDocument) { try ConnectionImport.decode(bytes) }
        }
        #expect(throws: ConnectionImportError.unsupportedVersion) { try ConnectionImport.decode(data(extra: ["version": 2])) }
        for field in ["password", "accessToken", "secretAccessKey", "sessionID", "passwordCredentialID", "localUsername", "hst"] {
            #expect(throws: ConnectionImportError.unsupportedFields) { try ConnectionImport.decode(data(extra: [field: "synthetic-secret"])) }
        }
        for fields: [String: Any] in [["engine": "sqlite"], ["authentication": "unknown"], ["upstreamPort": "5432"],
                                       ["tlsMode": "prefer"], ["localAuthentication": "none"], ["localPort": NSNull()],
                                       ["trust": "unverified"], ["accountID": 123456789012], ["localPort": 123.5]] {
            #expect(throws: ConnectionImportError.invalidDocument) { try ConnectionImport.decode(data(extra: fields)) }
        }
        struct PrivateError: Error, LocalizedError { var errorDescription: String? { "synthetic-secret" } }
        #expect(!ConnectionImportError.message(PrivateError()).contains("synthetic-secret"))
    }

    @Test func validatesPortsHostDatabaseAndIAMSettingsBeforeReview() throws {
        #expect(throws: ConfigurationError.invalidPort("Local port")) { try ConnectionImport.decode(data(extra: ["localPort": 65536])) }
        #expect(throws: ConfigurationError.invalidPort("Upstream port")) { try ConnectionImport.decode(data(extra: ["upstreamPort": 0])) }
        #expect(throws: ConfigurationError.invalidHost) { try ConnectionImport.decode(data(extra: ["host": "postgres://user@host/db"])) }
        #expect(throws: ConfigurationError.required("Database")) { try ConnectionImport.decode(data(extra: ["database": " "])) }
        #expect(throws: ConfigurationError.invalidDatabaseRegion) { try ConnectionImport.decode(data(extra: ["region": "invalid"])) }
        #expect(throws: ConfigurationError.invalidAccountID) { try ConnectionImport.decode(data(extra: ["accountID": "123"])) }
        #expect(throws: ConfigurationError.required("IAM database username")) { try ConnectionImport.decode(data(removing: ["username"])) }
        #expect(throws: ConfigurationError.required("AWS role")) { try ConnectionImport.decode(data(removing: ["roleName"])) }
        #expect(throws: ConfigurationError.iamRequiresTLS) { try ConnectionImport.decode(data(extra: ["tlsMode": "disabled"])) }
        #expect(throws: ConnectionImportError.conflictingAuthentication) { try ConnectionImport.decode(data(extra: ["credentialName": "login"])) }
        #expect(throws: ConnectionImportError.conflictingAuthentication) {
            try ConnectionImport.decode(data(authentication: "databasePassword", extra: ["username": "from-file"]))
        }
        let password = try ConnectionImport.decode(data(authentication: "databasePassword", extra: ["tlsMode": "disabled"]))
        #expect(try password.draft().tlsMode == .disabled)
    }

    @Test func fileLoadingIsBoundedAndRejectsDirectoriesAndNonFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ConnectionImport-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "database.json")
        try data().write(to: url)
        let document = try await ConnectionImport.load(from: url)
        #expect(try document.draft().name == "Imported")
        await #expect(throws: ConnectionImportError.unreadable) { try await ConnectionImport.load(from: folder) }
        await #expect(throws: ConnectionImportError.unreadable) { try await ConnectionImport.load(from: folder.appending(path: "missing.json")) }
        await #expect(throws: ConnectionImportError.unreadable) { try await ConnectionImport.load(from: URL(string: "https://example.test/file.json")!) }
        let oversized = Data(repeating: 32, count: ConnectionImport.maximumBytes + 1)
        #expect(throws: ConnectionImportError.tooLarge) { try ConnectionImport.decode(oversized) }
        try oversized.write(to: url)
        await #expect(throws: ConnectionImportError.tooLarge) { try await ConnectionImport.load(from: url) }
    }
}
