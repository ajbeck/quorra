import AWSConfigINI
import Foundation
import Testing
@testable import QuorraAppLogic

@Suite("Identity store export")
struct IdentityStoreExporterTests {
    private static let configText = """
[sso-session acme]
sso_start_url = https://old.awsapps.com/start
sso_region = us-west-2

# the dev profile
[profile dev]
sso_session = acme
sso_account_id = 111111111111
sso_role_name = OldRole
output = json

[profile gone]
sso_session = acme
sso_account_id = 222222222222
sso_role_name = DevAccess

[profile gone-but-mine]
sso_session = acme
sso_account_id = 333333333333
sso_role_name = DevAccess
output = text

[profile assume-role]
role_arn = arn:aws:iam::123456789012:role/MyRole
source_profile = dev
"""

    private let acme = ExportedSession(
        name: "acme",
        startURL: "https://acme.awsapps.com/start",
        region: "us-east-1",
        registrationScopes: ["sso:account:access"]
    )
    private let dev = ExportedProfile(
        name: "dev",
        sessionName: "acme",
        accountID: "111111111111",
        roleName: "DevAccess",
        region: "eu-west-1"
    )

    @Test func setsItsKeysAndKeepsForeignKeysCommentsAndOtherSections() throws {
        var document = try AWSConfigINIDocument(Self.configText, flavor: .config)
        let summary = IdentityStoreExporter.apply(
            IdentityExportSnapshot(sessions: [acme], profiles: [dev]),
            previous: .empty,
            to: &document
        )

        let session = try #require(document.section("sso-session acme"))
        #expect(session.key("sso_start_url")?.stringValue == "https://acme.awsapps.com/start")
        #expect(session.key("sso_region")?.stringValue == "us-east-1")
        #expect(session.key("sso_registration_scopes")?.stringValue == "sso:account:access")

        let profile = try #require(document.section("profile dev"))
        #expect(profile.key("sso_role_name")?.stringValue == "DevAccess")
        #expect(profile.key("region")?.stringValue == "eu-west-1")
        #expect(profile.key("output")?.stringValue == "json")
        #expect(try document.write().contains("# the dev profile"))

        #expect(document.section("profile assume-role")?.key("role_arn")?.stringValue == "arn:aws:iam::123456789012:role/MyRole")
        #expect(document.section("profile gone")?.key("sso_account_id")?.stringValue == "222222222222")
        #expect(summary.sessions == 1)
        #expect(summary.profiles == 1)
        #expect(summary.removedProfiles == 0)
    }

    @Test func addsSectionsForNewObjectsAndUsesTheBareDefaultSection() throws {
        var document = AWSConfigINIDocument(empty: .config)
        let defaultProfile = ExportedProfile(name: "default", sessionName: "acme", accountID: "444444444444", roleName: "Admin", region: nil)
        _ = IdentityStoreExporter.apply(
            IdentityExportSnapshot(sessions: [acme], profiles: [defaultProfile]),
            previous: .empty,
            to: &document
        )

        #expect(document.section("sso-session acme")?.key("sso_region")?.stringValue == "us-east-1")
        #expect(document.section("default")?.key("sso_session")?.stringValue == "acme")
        #expect(document.section("default")?.key("region") == nil)
        #expect(document.section("profile default") == nil)
    }

    @Test func removesOnlyItsKeysForObjectsDeletedInQuorra() throws {
        var document = try AWSConfigINIDocument(Self.configText, flavor: .config)
        let previous = IdentityExportRecord(sessionNames: ["acme"], profileNames: ["dev", "gone", "gone-but-mine"])
        let summary = IdentityStoreExporter.apply(
            IdentityExportSnapshot(sessions: [acme], profiles: [dev]),
            previous: previous,
            to: &document
        )

        #expect(document.section("profile gone") == nil)
        let kept = try #require(document.section("profile gone-but-mine"))
        #expect(kept.key("sso_session") == nil)
        #expect(kept.key("sso_account_id") == nil)
        #expect(kept.key("output")?.stringValue == "text")
        #expect(document.section("profile dev")?.key("sso_role_name")?.stringValue == "DevAccess")
        #expect(summary.removedProfiles == 2)
        #expect(summary.removedSessions == 0)
    }

    @Test func removesASessionDeletedInQuorra() throws {
        var document = try AWSConfigINIDocument(Self.configText, flavor: .config)
        let summary = IdentityStoreExporter.apply(
            IdentityExportSnapshot(sessions: [], profiles: []),
            previous: IdentityExportRecord(sessionNames: ["acme"], profileNames: []),
            to: &document
        )

        #expect(document.section("sso-session acme") == nil)
        #expect(document.section("profile dev")?.key("sso_session")?.stringValue == "acme")
        #expect(summary.removedSessions == 1)
    }

    @Test func emptyRegionAndScopesRemoveTheirKeys() throws {
        var document = try AWSConfigINIDocument(Self.configText, flavor: .config)
        var session = acme
        session.registrationScopes = []
        var profile = dev
        profile.region = ""
        _ = IdentityStoreExporter.apply(
            IdentityExportSnapshot(sessions: [session], profiles: [profile]),
            previous: .empty,
            to: &document
        )

        #expect(document.section("sso-session acme")?.key("sso_registration_scopes") == nil)
        #expect(document.section("profile dev")?.key("region") == nil)
        #expect(document.section("profile dev")?.key("output")?.stringValue == "json")
    }

    @Test func exportWritesTheFileUnderTheHeaderAndReturnsTheRecord() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config", directoryHint: .notDirectory)
        try Self.configText.write(to: url, atomically: true, encoding: .utf8)

        let result = try IdentityStoreExporter.export(
            IdentityExportSnapshot(sessions: [acme], profiles: [dev]),
            previous: .empty,
            toConfigAt: url
        )

        #expect(result.record == IdentityExportRecord(sessionNames: ["acme"], profileNames: ["dev"]))
        #expect(result.summary.profiles == 1)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix(AWSConfigINIDocumentOptions.default.managedHeaderText))
        let written = try AWSConfigINIDocument(contentsOf: url, flavor: .config)
        #expect(written.section("profile dev")?.key("sso_role_name")?.stringValue == "DevAccess")
        #expect(written.section("profile dev")?.key("output")?.stringValue == "json")
        #expect(written.section("profile assume-role")?.key("source_profile")?.stringValue == "dev")
    }

    @Test func exportCreatesAMissingConfigFile() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config", directoryHint: .notDirectory)

        _ = try IdentityStoreExporter.export(
            IdentityExportSnapshot(sessions: [acme], profiles: [dev]),
            previous: .empty,
            toConfigAt: url
        )

        let written = try AWSConfigINIDocument(contentsOf: url, flavor: .config)
        #expect(written.section("sso-session acme")?.key("sso_start_url")?.stringValue == "https://acme.awsapps.com/start")
        #expect(written.section("profile dev")?.key("sso_account_id")?.stringValue == "111111111111")
    }

    @Test func storageRoundTripsTheRecord() throws {
        let defaults = try #require(UserDefaults(suiteName: "IdentityExportStorageTests.\(UUID().uuidString)"))
        let storage = IdentityExportStorage(defaults: defaults)
        #expect(storage.load() == .empty)

        let record = IdentityExportRecord(sessionNames: ["acme"], profileNames: ["dev", "default"])
        storage.save(record)
        #expect(storage.load() == record)

        storage.clear()
        #expect(storage.load() == .empty)
    }

    @MainActor
    @Test func snapshotCapturesSessionsAndLinkedProfilesOnly() throws {
        let container = try QuorraMetadataSchema.makeContainer(inMemory: true)
        let context = container.mainContext
        let session = SessionDefinition(
            name: "acme",
            startURL: "https://acme.awsapps.com/start",
            region: "us-east-1",
            registrationScopes: ["sso:account:access"]
        )
        context.insert(session)
        context.insert(ProfileDefinition(name: "dev", session: session, accountID: "111111111111", roleName: "DevAccess", region: "eu-west-1"))
        context.insert(ProfileDefinition(name: "unlinked", session: nil, accountID: "222222222222", roleName: "DevAccess", region: nil))
        try context.save()

        let snapshot = try IdentityExportSnapshot.capture(in: context)

        #expect(snapshot.sessions == [acme])
        #expect(snapshot.profiles == [dev])
    }
}
