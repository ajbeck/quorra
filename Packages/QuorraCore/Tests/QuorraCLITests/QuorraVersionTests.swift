import Foundation
import Testing
@testable import QuorraCLIKit

@Suite("Quorra version")
struct QuorraVersionTests {
    @Test func matchesRepositoryReleaseVersion() throws {
        var repositoryURL = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 {
            repositoryURL.deleteLastPathComponent()
        }
        let versionURL = repositoryURL.appending(path: "version.txt", directoryHint: .notDirectory)
        let repositoryVersion = try String(contentsOf: versionURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(QuorraVersion.current == repositoryVersion)
    }

    @Test func packagedCLIUsesItsBundleMarketingVersion() {
        #expect(
            QuorraVersion.resolve(
                bundleIdentifier: "dev.ajbeck.quorra.cli",
                bundledVersion: "0.6.0"
            ) == "0.6.0"
        )
    }

    @Test func unrelatedBundlesUseTheRepositoryVersion() {
        #expect(
            QuorraVersion.resolve(
                bundleIdentifier: "com.apple.dt.xctest.tool",
                bundledVersion: "99.0"
            ) == QuorraVersion.current
        )
    }
}
