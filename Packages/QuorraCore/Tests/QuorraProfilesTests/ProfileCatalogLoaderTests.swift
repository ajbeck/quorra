import Foundation
import Testing
@testable import QuorraProfiles

@Suite("ProfileCatalogLoader")
struct ProfileCatalogLoaderTests {
    @Test func loadsSeparateConfigAndCredentialsFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let configURL = directory.appending(path: "custom-config", directoryHint: .notDirectory)
        let credentialsURL = directory.appending(path: "custom-credentials", directoryHint: .notDirectory)
        try """
        [profile development]
        region = eu-west-2
        """.write(to: configURL, atomically: true, encoding: .utf8)
        try """
        [automation]
        aws_access_key_id = test-access-key
        aws_secret_access_key = test-secret-key
        """.write(to: credentialsURL, atomically: true, encoding: .utf8)

        let catalog = try ProfileCatalogLoader.load(
            configURL: configURL,
            credentialsURL: credentialsURL
        )

        #expect(catalog.groups.other.map(\.id) == ["development"])
        #expect(catalog.groups.longTermKeys.map(\.id) == ["automation"])
        #expect(catalog.groups.other.first?.profile.region == "eu-west-2")
    }

    @Test func treatsMissingFilesAsEmptyDocuments() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let catalog = try ProfileCatalogLoader.load(folder: directory)

        #expect(catalog.configDocument.sections.isEmpty)
        #expect(catalog.credentialsDocument.sections.isEmpty)
        #expect(catalog.groups == .empty)
    }
}
