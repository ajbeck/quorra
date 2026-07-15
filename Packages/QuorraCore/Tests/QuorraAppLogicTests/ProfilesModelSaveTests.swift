import Foundation
import Testing
import AWSConfigINI
@testable import QuorraAppLogic

@MainActor
struct ProfilesModelSaveTests {

    private func makeTempFolder() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func writeConfig(_ text: String, in folder: URL) throws {
        try text.write(
            to: folder.appending(path: "config", directoryHint: .notDirectory),
            atomically: true,
            encoding: .utf8
        )
    }

    private static let minimalConfig = """
[default]
region = us-east-1
"""

    @Test func save_writes_profile_to_config_file_with_managed_header() async throws {
        let folder = try makeTempFolder()
        try writeConfig(Self.minimalConfig, in: folder)

        let model = ProfilesModel()
        await model.load(folder: folder)

        let node = try #require(model.findProfile(named: "default"))
        var updated = node.profile
        updated.region = "eu-west-1"

        try await model.save(updated, for: node)

        let written = try String(contentsOf: folder.appending(path: "config"), encoding: .utf8)
        #expect(written.contains("eu-west-1"))
        #expect(written.contains("# Managed by Quorra"))
    }

    @Test func save_subsequent_writes_do_not_duplicate_header() async throws {
        let folder = try makeTempFolder()
        try writeConfig(Self.minimalConfig, in: folder)

        let model = ProfilesModel()
        await model.load(folder: folder)

        let node1 = try #require(model.findProfile(named: "default"))
        var updated1 = node1.profile
        updated1.region = "ap-southeast-1"
        try await model.save(updated1, for: node1)

        let node2 = try #require(model.findProfile(named: "default"))
        var updated2 = node2.profile
        updated2.region = "ap-northeast-1"
        try await model.save(updated2, for: node2)

        let written = try String(contentsOf: folder.appending(path: "config"), encoding: .utf8)
        let headerCount = written.components(separatedBy: "# Managed by Quorra").count - 1
        #expect(headerCount == 1)
    }

    @Test func save_reloads_groups_on_success() async throws {
        let folder = try makeTempFolder()
        try writeConfig(Self.minimalConfig, in: folder)

        let model = ProfilesModel()
        await model.load(folder: folder)

        let node = try #require(model.findProfile(named: "default"))
        var updated = node.profile
        updated.region = "ca-central-1"
        try await model.save(updated, for: node)

        let reloadedNode = try #require(model.findProfile(named: "default"))
        #expect(reloadedNode.profile.region == "ca-central-1")
    }

    @Test func save_session_writes_to_config() async throws {
        let folder = try makeTempFolder()
        try writeConfig("""
[sso-session corp]
sso_start_url = https://corp.awsapps.com/start
sso_region = us-east-1

[default]
sso_session = corp
region = us-east-1
""", in: folder)

        let model = ProfilesModel()
        await model.load(folder: folder)

        let node = try #require(model.findSession(named: "corp"))
        var updated = node.session ?? SSOSession()
        updated.ssoRegion = "eu-central-1"
        try await model.save(updated, for: node)

        let written = try String(contentsOf: folder.appending(path: "config"), encoding: .utf8)
        #expect(written.contains("eu-central-1"))

        let reloadedNode = try #require(model.findSession(named: "corp"))
        #expect(reloadedNode.session?.ssoRegion == "eu-central-1")
    }
}
