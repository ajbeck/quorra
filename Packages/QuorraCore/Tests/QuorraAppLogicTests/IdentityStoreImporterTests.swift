import AWSConfigINI
import Foundation
import SwiftData
import Testing
@testable import QuorraAppLogic

@Suite("Identity store import")
struct IdentityStoreImporterTests {
    private static let configText = """
[sso-session acme]
sso_start_url = https://acme.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access, sso:role:read

[profile dev]
sso_session = acme
sso_account_id = 222222222222
sso_role_name = DevAccess
region = eu-west-1

[profile incomplete]
sso_session = acme

[profile keys]
aws_access_key_id = AKIAEXAMPLE
aws_secret_access_key = example

[sso-session broken]
sso_region = us-east-1

[profile orphan]
sso_session = broken
sso_account_id = 333333333333
sso_role_name = DevAccess
"""

    private func groups(_ text: String = configText) throws -> SidebarGroups {
        let config = try AWSConfigINIDocument(text, flavor: .config)
        return ProfileCatalogLoader.derive(config: config, credentials: AWSConfigINIDocument(empty: .credentials))
    }

    @MainActor
    @Test func imports_sessions_and_sso_profiles_and_leaves_the_rest_in_the_file() throws {
        let container = try QuorraMetadataSchema.makeContainer(inMemory: true)
        let context = container.mainContext

        let summary = try IdentityStoreImporter.importSSOProfiles(from: groups(), into: context)

        #expect(summary.sessions == 1)
        #expect(summary.profiles == 1)
        #expect(summary.skippedProfiles.sorted() == ["incomplete", "orphan"])
        let sessions = try context.fetch(FetchDescriptor<SessionDefinition>())
        #expect(sessions.map(\.name) == ["acme"])
        #expect(sessions.first?.startURL == "https://acme.awsapps.com/start")
        #expect(sessions.first?.registrationScopes == ["sso:account:access", "sso:role:read"])
        let profiles = try context.fetch(FetchDescriptor<ProfileDefinition>())
        #expect(profiles.map(\.name) == ["dev"])
        #expect(profiles.first?.accountID == "222222222222")
        #expect(profiles.first?.roleName == "DevAccess")
        #expect(profiles.first?.region == "eu-west-1")
        #expect(profiles.first?.session?.name == "acme")
    }

    @MainActor
    @Test func importing_again_updates_records_instead_of_duplicating_them() throws {
        let container = try QuorraMetadataSchema.makeContainer(inMemory: true)
        let context = container.mainContext
        _ = try IdentityStoreImporter.importSSOProfiles(from: groups(), into: context)
        let originalSessionID = try #require(try context.fetch(FetchDescriptor<SessionDefinition>()).first).stableIDString

        let changed = Self.configText.replacingOccurrences(of: "region = eu-west-1", with: "region = ap-southeast-2")
        let summary = try IdentityStoreImporter.importSSOProfiles(from: groups(changed), into: context)

        #expect(summary.sessions == 1)
        #expect(summary.profiles == 1)
        let sessions = try context.fetch(FetchDescriptor<SessionDefinition>())
        #expect(sessions.count == 1)
        #expect(sessions.first?.stableIDString == originalSessionID)
        let profiles = try context.fetch(FetchDescriptor<ProfileDefinition>())
        #expect(profiles.count == 1)
        #expect(profiles.first?.region == "ap-southeast-2")
    }

    @MainActor
    @Test func import_links_endpoints_to_profiles_by_name() throws {
        let container = try QuorraMetadataSchema.makeContainer(inMemory: true)
        let context = container.mainContext
        let linked = IMDSEndpointDefinition(name: "Terraform", profileName: "dev", port: 9678)
        let unlinked = IMDSEndpointDefinition(name: "Old", profileName: "missing", port: 9679)
        context.insert(linked)
        context.insert(unlinked)
        try context.save()

        let summary = try IdentityStoreImporter.importSSOProfiles(from: groups(), into: context)

        #expect(summary.linkedEndpoints == 1)
        #expect(linked.profile?.name == "dev")
        #expect(unlinked.profile == nil)
    }
}
