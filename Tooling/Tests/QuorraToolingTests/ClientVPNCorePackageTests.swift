@testable import QuorraTooling
import Foundation
import Testing

struct ClientVPNCorePackageTests {
    private func package() throws -> Scratch {
        let scratch = try Scratch("native-package")
        try scratch.copy([
            "Tooling/Sources/QuorraTooling/ClientVPNCoreReview.swift",
            "Tooling/Sources/QuorraTooling/ClientVPNCorePackage.swift",
            ClientVPNCoreReview.fixtureDirectory,
            "\(ClientVPNCorePackage.packagePath)/SourceNotice.md",
        ])
        let package = scratch.url.appendingPathComponent(ClientVPNCorePackage.packagePath)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("Artifacts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("Sources/QuorraOpenVPN/Resources"), withIntermediateDirectories: true)
        try write("synthetic library", package.appendingPathComponent("Artifacts/core.a").path)
        try write("synthetic notice", package.appendingPathComponent("Sources/QuorraOpenVPN/Resources/notice.txt").path)
        var manifest = try ClientVPNCorePackage.recipeDigests(root: scratch.url)
        manifest["Artifacts/core.a"] = digest(Data("synthetic library".utf8))
        manifest["Resources/notice.txt"] = digest(Data("synthetic notice".utf8))
        try write(JSONEncoder().encode(manifest), package.appendingPathComponent("ArtifactManifest.json").path)
        return scratch
    }

    @Test func missingArtifactRootAndSymbolicLinksAreRejected() throws {
        let scratch = try Scratch("native-files")
        #expect(failure { _ = try ClientVPNCorePackage.fileDigests(in: scratch.url.appendingPathComponent("missing")) } == "Cannot read native package artifacts.")
        try FileManager.default.createSymbolicLink(atPath: scratch.file("link"), withDestinationPath: "/nonexistent-synthetic-path")
        #expect(failure { _ = try ClientVPNCorePackage.fileDigests(in: scratch.url) } == "Native package artifacts must not contain symbolic links.")
    }

    @Test(arguments: ["Artifacts/core.a", "Sources/QuorraOpenVPN/Resources/notice.txt", "Artifacts/extra.a"])
    func changedMissingOrAdditionalArtifactsFailIntegrityChecks(path: String) throws {
        let scratch = try package()
        _ = try ClientVPNCorePackage.check(root: scratch.url)
        try write("changed", scratch.file("\(ClientVPNCorePackage.packagePath)/\(path)"))
        #expect(failure { _ = try ClientVPNCorePackage.check(root: scratch.url) }.contains("differ from their manifest"))
    }

    @Test func localPatchChangesRequireRegeneratingThePackage() throws {
        let scratch = try package()
        try write("changed", scratch.file("\(ClientVPNCoreReview.fixtureDirectory)/002-awslc-certificate-policy.patch"))
        #expect(failure { _ = try ClientVPNCorePackage.check(root: scratch.url) }.contains("differ from their manifest"))
    }

    @Test func rebuildComparisonChecksTheFilesAsWellAsTheManifest() throws {
        let scratch = try package()
        let rebuilt = try Scratch("rebuilt-package")
        let source = scratch.url.appendingPathComponent(ClientVPNCorePackage.packagePath)
        for (from, to) in [("Artifacts", "Artifacts"), ("Sources/QuorraOpenVPN/Resources", "Resources"), ("ArtifactManifest.json", "ArtifactManifest.json")] {
            try FileManager.default.copyItem(at: source.appendingPathComponent(from), to: rebuilt.url.appendingPathComponent(to))
        }
        _ = try ClientVPNCorePackage.check(root: scratch.url, rebuilt: rebuilt.url)
        try write("changed", rebuilt.file("Artifacts/core.a"))
        #expect(failure { _ = try ClientVPNCorePackage.check(root: scratch.url, rebuilt: rebuilt.url) } == "Rebuilt native VPN files differ from their manifest.")
        try write("{}", rebuilt.file("ArtifactManifest.json"))
        #expect(failure { _ = try ClientVPNCorePackage.check(root: scratch.url, rebuilt: rebuilt.url) } == "Rebuilt native VPN package differs from the committed artifacts.")
    }

    @Test func exporterRefusesLibraryWithoutMatchingReviewEvidence() throws {
        let scratch = try package()
        let review = try Scratch("review-package")
        try write("synthetic library", review.file("libQuorraOpenVPNCore.a"))
        try write("SHA-256: incorrect\n", review.file("results.txt"))
        let output = scratch.url.appendingPathComponent("new-package")
        #expect(failure { _ = try ClientVPNCorePackage.build(root: scratch.url, review: review.url, output: output) } == "Native core does not match its completed review.")
        #expect(!exists(output.path))
    }

    @Test func explicitDownloadUsesHTTPSAndStopsOnCorruptBytesBeforeBuilding() throws {
        let scratch = try package()
        let stub = scratch.file("curl")
        try write("""
        #!/bin/bash
        set -eu
        printf '%s\\n' "$@" > "$FAKE_CURL_ARGUMENTS"
        while [[ $# -gt 0 ]]; do
          if [[ "$1" == --output ]]; then
            printf '%s' 'corrupt archive' > "$2"
            exit 0
          fi
          shift
        done
        exit 9

        """, stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub)
        let process = Process()
        process.executableURL = Bundle(for: Scratch.self).bundleURL.deletingLastPathComponent().appendingPathComponent("quorra-tooling")
        process.arguments = ["build", "vpn-core-review", "--download", "--root", scratch.path, "--archives", scratch.file("downloads"), "--output", scratch.file("build")]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(scratch.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["FAKE_CURL_ARGUMENTS"] = scratch.file("arguments")
        process.environment = environment
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus != 0 && !exists(scratch.file("build")))
        let arguments = String(decoding: try read(scratch.file("arguments")), as: UTF8.self)
        #expect(arguments.hasPrefix("--disable\n--proto\n=https\n--proto-redir\n=https\n"))
        #expect(arguments.contains("--max-filesize\n268435456\n"))
    }
}
