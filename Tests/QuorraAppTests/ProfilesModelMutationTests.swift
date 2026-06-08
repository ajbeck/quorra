import Foundation
import Testing
import AWSConfigINI
@testable import quorra

@Suite("ProfilesModel mutations")
@MainActor
struct ProfilesModelMutationTests {
    @Test func creates_and_deletes_profile_sections() async throws {
        let folder = try makeAWSFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try write(
            """
            [sso-session acme]
            sso_region = us-east-1
            """,
            to: folder.appending(path: "config")
        )

        let model = ProfilesModel()
        await model.load(folder: folder)

        try await model.createProfile(
            named: "dev",
            profile: Profile(region: "us-east-1", ssoSession: "acme", ssoAccountId: "123456789012", ssoRoleName: "Developer"),
            mode: .managed
        )

        #expect(model.findProfile(named: "dev")?.profile.ssoSession == "acme")
        var config = try AWSConfigINIDocument(contentsOf: folder.appending(path: "config"), flavor: .config)
        #expect(config.section("profile dev") != nil)

        try await model.deleteProfile(named: "dev", mode: .managed)

        #expect(model.findProfile(named: "dev") == nil)
        config = try AWSConfigINIDocument(contentsOf: folder.appending(path: "config"), flavor: .config)
        #expect(config.section("profile dev") == nil)
    }

    @Test func creates_and_deletes_sso_session_sections() async throws {
        let folder = try makeAWSFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let model = ProfilesModel()
        await model.load(folder: folder)

        try await model.createSession(
            named: "acme",
            session: SSOSession(
                ssoStartUrl: "https://acme.awsapps.com/start",
                ssoRegion: "us-east-1",
                ssoRegistrationScopes: ["sso:account:access"]
            ),
            mode: .managed
        )

        #expect(model.findSession(named: "acme")?.session?.ssoRegion == "us-east-1")
        var config = try AWSConfigINIDocument(contentsOf: folder.appending(path: "config"), flavor: .config)
        #expect(config.section("sso-session acme") != nil)

        try await model.deleteSession(named: "acme", mode: .managed)

        #expect(model.findSession(named: "acme") == nil)
        config = try AWSConfigINIDocument(contentsOf: folder.appending(path: "config"), flavor: .config)
        #expect(config.section("sso-session acme") == nil)
    }

    private func makeAWSFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "quorra-profiles-model-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
