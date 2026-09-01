import Foundation
import Testing
@testable import QuorraAppLogic

@Suite("GitHub release update checks")
struct GitHubReleaseCheckerTests {
    @Test func releaseVersionParsesTagsAndComparesNumerically() throws {
        let current = try #require(ReleaseVersion("v0.1.9"))
        let update = try #require(ReleaseVersion("0.1.10"))

        #expect(current < update)
        #expect(ReleaseVersion("1.0") == ReleaseVersion("1.0.0"))
        #expect(Set([ReleaseVersion("1.0")!, ReleaseVersion("1.0.0")!]).count == 1)
        #expect(ReleaseVersion("V2.3.4")?.description == "2.3.4")
    }

    @Test func releaseVersionRejectsMalformedValues() {
        #expect(ReleaseVersion("") == nil)
        #expect(ReleaseVersion("v") == nil)
        #expect(ReleaseVersion("1..2") == nil)
        #expect(ReleaseVersion("1.2.beta") == nil)
        #expect(ReleaseVersion("1.2.3-beta.1") == nil)
    }

    @Test func newerLatestReleaseReturnsDownloadableUpdate() async throws {
        let data = try releaseJSON(
            tag: "v0.2.0",
            assets: [
                asset(name: "Quorra-0.2.0.dmg", contentType: "application/x-apple-diskimage"),
            ]
        )
        let checker = checker(data: data) { request in
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
            #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2026-03-10")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "Quorra")
        }

        let result = try await checker.check(currentVersion: #require(ReleaseVersion("0.1.2")))
        guard case .updateAvailable(let release) = result else {
            Issue.record("Expected an available update")
            return
        }
        #expect(release.version == ReleaseVersion("0.2.0"))
        #expect(release.diskImageURL?.lastPathComponent == "Quorra-0.2.0.dmg")
    }

    @Test func equalLatestReleaseIsUpToDate() async throws {
        let checker = checker(data: try releaseJSON(tag: "v0.1.2"))
        let result = try await checker.check(currentVersion: #require(ReleaseVersion("0.1.2")))

        guard case .upToDate(let release) = result else {
            Issue.record("Expected an up-to-date result")
            return
        }
        #expect(release.tagName == "v0.1.2")
    }

    @Test func newerLocalVersionIsRecognizedAsDevelopmentBuild() async throws {
        let checker = checker(data: try releaseJSON(tag: "v0.1.2"))
        let result = try await checker.check(currentVersion: #require(ReleaseVersion("1.0")))

        guard case .developmentBuild(let release) = result else {
            Issue.record("Expected a development-build result")
            return
        }
        #expect(release.version == ReleaseVersion("0.1.2"))
    }

    @Test func releaseWithoutDiskImageFallsBackToReleasePage() async throws {
        let data = try releaseJSON(
            tag: "v0.2.0",
            assets: [asset(name: "source.zip", contentType: "application/zip")]
        )
        let release = try await checker(data: data).latestRelease()

        #expect(release.diskImageURL == nil)
        #expect(release.releaseURL.absoluteString == "https://github.com/ajbeck/quorra/releases/tag/v0.2.0")
    }

    @Test func exactVersionedDiskImageIsPreferred() async throws {
        let data = try releaseJSON(
            tag: "v0.2.0",
            assets: [
                asset(name: "Quorra-preview.dmg", contentType: "application/x-apple-diskimage"),
                asset(name: "Quorra-0.2.0.dmg", contentType: "application/x-apple-diskimage"),
            ]
        )
        let release = try await checker(data: data).latestRelease()

        #expect(release.diskImageURL?.lastPathComponent == "Quorra-0.2.0.dmg")
    }

    @Test func nonSuccessStatusIsRejected() async throws {
        let checker = checker(data: Data(), statusCode: 403)

        await #expect(throws: GitHubReleaseCheckError.httpStatus(403)) {
            try await checker.latestRelease()
        }
    }

    @Test func malformedJSONIsRejected() async throws {
        let checker = checker(data: Data("not-json".utf8))

        await #expect(throws: GitHubReleaseCheckError.malformedRelease) {
            try await checker.latestRelease()
        }
    }

    @Test func insecureReleaseURLIsRejected() async throws {
        let data = try releaseJSON(tag: "v0.2.0", htmlURL: "http://example.com/release")
        let checker = checker(data: data)

        await #expect(throws: GitHubReleaseCheckError.malformedRelease) {
            try await checker.latestRelease()
        }
    }

    private func checker(
        data: Data,
        statusCode: Int = 200,
        inspectRequest: @escaping @Sendable (URLRequest) -> Void = { _ in }
    ) -> GitHubReleaseChecker {
        GitHubReleaseChecker(
            endpoint: URL(string: "https://api.github.com/repos/ajbeck/quorra/releases/latest")!,
            dataLoader: { request in
                inspectRequest(request)
                return (data, statusCode)
            }
        )
    }

    private func releaseJSON(
        tag: String,
        htmlURL: String? = nil,
        assets: [[String: Any]] = []
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tag_name": tag,
            "html_url": htmlURL ?? "https://github.com/ajbeck/quorra/releases/tag/\(tag)",
            "assets": assets,
        ])
    }

    private func asset(name: String, contentType: String) -> [String: Any] {
        [
            "name": name,
            "state": "uploaded",
            "content_type": contentType,
            "browser_download_url": "https://github.com/ajbeck/quorra/releases/download/v0.2.0/\(name)",
        ]
    }
}
