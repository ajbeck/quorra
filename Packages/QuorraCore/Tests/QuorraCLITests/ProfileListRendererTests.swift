import Foundation
import QuorraIPC
import Testing
@testable import QuorraCLIKit

@Suite("ProfileListRenderer")
struct ProfileListRendererTests {
    private let profiles = [
        QuorraProfileRecord(name: "default", sessionName: "corp", accountID: "111111111111", roleName: "AdministratorAccess", region: nil),
        QuorraProfileRecord(name: "development", sessionName: nil, accountID: "222222222222", roleName: "DevAccess", region: "eu-west-1"),
    ]

    @Test func rendersNamesInStoreOrder() throws {
        let output = try ProfileListRenderer.render(profiles, format: .names)

        #expect(output == "default\ndevelopment")
    }

    @Test func rendersMachineReadableJSON() throws {
        let output = try ProfileListRenderer.render(profiles, format: .json)
        let data = try #require(output.data(using: .utf8))
        let objects = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        #expect(objects.map { $0["name"] as? String } == ["default", "development"])
        #expect(objects[0]["session"] as? String == "corp")
        #expect(objects[0]["account"] as? String == "111111111111")
        #expect(objects[1]["region"] as? String == "eu-west-1")
        #expect(objects[1]["session"] == nil)
    }

    @Test func rendersTableWithStableColumns() throws {
        let output = try ProfileListRenderer.render(profiles, format: .table)
        let lines = output.split(separator: "\n")

        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("NAME"))
        #expect(lines[0].contains("SESSION"))
        #expect(lines[0].contains("ROLE"))
        #expect(lines[1].contains("default") && lines[1].contains("corp"))
        #expect(lines[2].contains("development") && lines[2].contains("—"))
    }
}
