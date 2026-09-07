import AWSConfigINI
import Foundation
import QuorraProfiles
import Testing
@testable import QuorraCLIKit

@Suite("ProfileListRenderer")
struct ProfileListRendererTests {
    @Test func rendersNamesInCatalogOrder() throws {
        let output = try ProfileListRenderer.render(items(), format: .names)

        #expect(output == "default\ndevelopment")
    }

    @Test func rendersMachineReadableJSONWithoutCredentialFields() throws {
        let output = try ProfileListRenderer.render(items(), format: .json)
        let data = try #require(output.data(using: .utf8))
        let objects = try #require(JSONSerialization.jsonObject(with: data) as? [[String: String]])

        #expect(objects.map { $0["name"] } == ["default", "development"])
        #expect(objects[0]["session"] == "corp")
        #expect(!output.contains("access_key"))
        #expect(!output.contains("secret"))
    }

    @Test func rendersTableWithStableColumns() throws {
        let output = try ProfileListRenderer.render(items(), format: .table)
        let lines = output.split(separator: "\n")

        #expect(lines.count == 3)
        #expect(lines[0].contains("NAME"))
        #expect(lines[0].contains("SOURCE"))
        #expect(lines[1].contains("default"))
        #expect(lines[2].contains("development"))
    }

    private func items() throws -> [SidebarProfileItem] {
        let config = try AWSConfigINIDocument("""
        [sso-session corp]
        sso_region = eu-west-2

        [default]
        sso_session = corp
        sso_account_id = 111111111111
        sso_role_name = AdministratorAccess

        [profile development]
        region = eu-west-1
        """, flavor: .config)
        let credentials = AWSConfigINIDocument(empty: .credentials)
        return ProfileCatalogLoader.derive(
            config: config,
            credentials: credentials
        ).flatProfiles
    }
}
