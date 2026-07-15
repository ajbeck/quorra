import Testing
import Foundation
import AWSConfigINI
@testable import QuorraAppLogic

@Suite("ProfilesModel.derive")
struct ProfilesModelDerivationTests {

    private func config(_ text: String) throws -> AWSConfigINIDocument {
        try AWSConfigINIDocument(text, flavor: .config)
    }

    private func credentials(_ text: String) throws -> AWSConfigINIDocument {
        try AWSConfigINIDocument(text, flavor: .credentials)
    }

    private static let emptyConfig = AWSConfigINIDocument(empty: .config)
    private static let emptyCredentials = AWSConfigINIDocument(empty: .credentials)

    @Test func derive_groups_sso_profiles_under_session() throws {
        let cfg = try config("""
[sso-session acme]
sso_start_url = https://acme.awsapps.com/start
sso_region = us-east-1

[default]
sso_session = acme
sso_account_id = 111111111111
sso_role_name = DevAccess

[profile dev]
sso_session = acme
sso_account_id = 222222222222
sso_role_name = DevAccess

[profile staging]
sso_session = acme
sso_account_id = 333333333333
sso_role_name = DevAccess
""")
        let groups = ProfilesModel.derive(config: cfg, credentials: Self.emptyCredentials)

        #expect(groups.ssoSessions.count == 1)
        let session = try #require(groups.ssoSessions.first)
        #expect(session.id == "acme")
        #expect(session.profiles.count == 3)
        #expect(groups.longTermKeys.isEmpty)
        #expect(groups.other.isEmpty)
    }

    @Test func derive_session_with_zero_profiles_appears() throws {
        let cfg = try config("""
[sso-session acme]
sso_start_url = https://acme.awsapps.com/start
sso_region = us-east-1
""")
        let groups = ProfilesModel.derive(config: cfg, credentials: Self.emptyCredentials)

        #expect(groups.ssoSessions.count == 1)
        let session = try #require(groups.ssoSessions.first)
        #expect(session.id == "acme")
        #expect(session.profiles.isEmpty)
    }

    @Test func derive_long_term_keys_from_credentials() throws {
        let creds = try credentials("""
[default]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
""")
        let groups = ProfilesModel.derive(config: Self.emptyConfig, credentials: creds)

        #expect(groups.longTermKeys.count == 1)
        #expect(groups.longTermKeys.first?.id == "default")
        #expect(groups.ssoSessions.isEmpty)
        #expect(groups.other.isEmpty)
    }

    @Test func derive_long_term_keys_from_config() throws {
        let cfg = try config("""
[default]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
region = us-east-1
""")
        let groups = ProfilesModel.derive(config: cfg, credentials: Self.emptyCredentials)

        #expect(groups.longTermKeys.count == 1)
        #expect(groups.longTermKeys.first?.id == "default")
        #expect(groups.ssoSessions.isEmpty)
        #expect(groups.other.isEmpty)
    }

    @Test func derive_other_role_assumption() throws {
        let cfg = try config("""
[profile assume-role]
role_arn = arn:aws:iam::123456789012:role/MyRole
source_profile = default
""")
        let groups = ProfilesModel.derive(config: cfg, credentials: Self.emptyCredentials)

        #expect(groups.other.count == 1)
        #expect(groups.other.first?.id == "assume-role")
        #expect(groups.ssoSessions.isEmpty)
        #expect(groups.longTermKeys.isEmpty)
    }

    @Test func derive_other_credential_process_only() throws {
        let cfg = try config("""
[profile cred-process]
credential_process = /usr/local/bin/quorra-cli credentials --profile cred-process
""")
        let groups = ProfilesModel.derive(config: cfg, credentials: Self.emptyCredentials)

        #expect(groups.other.count == 1)
        #expect(groups.other.first?.id == "cred-process")
        #expect(groups.ssoSessions.isEmpty)
        #expect(groups.longTermKeys.isEmpty)
    }

    @Test func derive_default_first_within_group() throws {
        let cfg = try config("""
[sso-session corp]
sso_region = us-east-1

[profile zebra]
sso_session = corp
sso_account_id = 111

[default]
sso_session = corp
sso_account_id = 222

[profile alpha]
sso_session = corp
sso_account_id = 333
""")
        let groups = ProfilesModel.derive(config: cfg, credentials: Self.emptyCredentials)

        let session = try #require(groups.ssoSessions.first)
        #expect(session.profiles.first?.id == "default")
        let remaining = session.profiles.dropFirst().map(\.id)
        #expect(remaining == ["alpha", "zebra"])
    }

    @Test func derive_credentials_overrides_config_per_key() throws {
        let cfg = try config("""
[default]
region = us-east-1
output = json
""")
        let creds = try credentials("""
[default]
region = eu-west-1
""")
        let groups = ProfilesModel.derive(config: cfg, credentials: creds)

        // default appears in both files; credentials side has no aws_access_key_id → lands in other
        let node = groups.other.first(where: { $0.id == "default" })
            ?? groups.longTermKeys.first(where: { $0.id == "default" })
        let unwrapped = try #require(node)
        #expect(unwrapped.profile.region == "eu-west-1")
        #expect(unwrapped.profile.output == "json")
    }

    @Test func derive_sessions_in_source_order() throws {
        let cfg = try config("""
[sso-session zebra]
sso_region = us-east-1

[sso-session apple]
sso_region = eu-west-1

[sso-session mango]
sso_region = ap-southeast-1
""")
        let groups = ProfilesModel.derive(config: cfg, credentials: Self.emptyCredentials)

        let ids = groups.ssoSessions.map(\.id)
        #expect(ids == ["zebra", "apple", "mango"])
    }

    @Test func derive_origin_tracked_correctly() throws {
        let cfg = try config("""
[profile config-only]
region = us-east-1

[profile both-files]
region = us-west-2
""")
        let creds = try credentials("""
[creds-only]
aws_access_key_id = AKID
aws_secret_access_key = SECRET

[both-files]
region = ap-southeast-1
""")
        let groups = ProfilesModel.derive(config: cfg, credentials: creds)

        let configOnly = try #require(groups.other.first(where: { $0.id == "config-only" }))
        #expect(configOnly.origin == .configOnly)

        let credsOnly = try #require(groups.longTermKeys.first(where: { $0.id == "creds-only" }))
        #expect(credsOnly.origin == .credentialsOnly)

        // both-files: present in both documents; no aws_access_key_id anywhere → other
        let bothFiles = try #require(groups.other.first(where: { $0.id == "both-files" }))
        #expect(bothFiles.origin == .both)
    }
}

@Suite("ProfilesModel.load")
@MainActor
struct ProfilesModelLoadTests {

    @Test func load_populates_groups_from_temp_folder() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configText = """
[sso-session corp]
sso_start_url = https://corp.awsapps.com/start
sso_region = us-east-1

[default]
sso_session = corp
sso_account_id = 123456789012
sso_role_name = DevAccess
"""
        try configText.write(
            to: tmpDir.appending(path: "config", directoryHint: .notDirectory),
            atomically: true,
            encoding: .utf8
        )

        let model = ProfilesModel()
        await model.load(folder: tmpDir)

        #expect(model.loadState == .loaded)
        #expect(!model.groups.ssoSessions.isEmpty)
        #expect(model.groups.ssoSessions.first?.id == "corp")
        #expect(model.groups.ssoSessions.first?.profiles.count == 1)
    }

    @Test func load_handles_missing_files_gracefully() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let model = ProfilesModel()
        await model.load(folder: tmpDir)

        #expect(model.loadState == .loaded)
        #expect(model.groups == .empty)
    }

    #if DEBUG
    @Test func seed_loaded_for_testing_matches_loaded_model_shape() throws {
        let folder = URL(filePath: "/preview/.aws", directoryHint: .isDirectory)
        let cfg = try AWSConfigINIDocument("""
[sso-session corp]
sso_region = us-east-1

[default]
sso_session = corp
sso_account_id = 123456789012
sso_role_name = DevAccess
""", flavor: .config)
        let creds = AWSConfigINIDocument(empty: .credentials)

        let model = ProfilesModel()
        let groups = model.seedLoadedForTesting(config: cfg, credentials: creds, folder: folder)

        #expect(model.loadState == .loaded)
        #expect(model.currentFolder == folder)
        #expect(model.configDocument?.flavor == cfg.flavor)
        #expect(model.configDocument?.sections.map(\.name) == cfg.sections.map(\.name))
        #expect(model.credentialsDocument?.flavor == creds.flavor)
        #expect(model.credentialsDocument?.sections.map(\.name) == creds.sections.map(\.name))
        #expect(model.groups == groups)
        #expect(model.findProfile(named: "default") != nil)
    }
    #endif
}
