@testable import QuorraTooling
import Foundation
import Testing

struct ClientVPNCoreReviewTests {
    private var syntheticSource: ClientVPNCoreReview.Source {
        .init(id: "synthetic", version: "1", revision: nil, archive: "synthetic.tar.gz", directory: "synthetic-1", url: "https://example.invalid/synthetic.tar.gz", sha256: digest(Data("synthetic".utf8)))
    }

    @Test func verifiedBytesAreRequiredBeforeArchiveExtraction() throws {
        try ClientVPNCoreReview.verify(Data("synthetic".utf8), source: syntheticSource)
        #expect(failure { try ClientVPNCoreReview.verify(Data("changed".utf8), source: syntheticSource) } == "Checksum mismatch for synthetic.tar.gz.")
    }

    @Test(arguments: ["", "/synthetic-1/file\n", "synthetic-1/../outside\n", "another-root/file\n", "synthetic-1/../../file\n"])
    func archivePathsCannotEscapeThePinnedRoot(listing: String) {
        #expect(!failure { try ClientVPNCoreReview.validateArchiveListing(listing, source: syntheticSource) }.isEmpty)
    }

    @Test func vendorMetadataDoesNotHideUnexpectedRoots() throws {
        try ClientVPNCoreReview.validateArchiveListing("._synthetic-1\nsynthetic-1/\nsynthetic-1/._file\nsynthetic-1/file\n", source: syntheticSource)
        #expect(failure { try ClientVPNCoreReview.validateArchiveListing("._outside\n", source: syntheticSource) } == "Unexpected source archive root.")
    }

    @Test func existingOutputIsNeverRemovedOrReused() throws {
        let scratch = try Scratch("native-review-output")
        try write("keep", scratch.file("marker"))
        #expect(failure { try ClientVPNCoreReview.createOutput(scratch.url) } == "Review output already exists; choose a new directory.")
        #expect(try read(scratch.file("marker")) == Data("keep".utf8))
    }

    @Test func corruptInputStopsBeforeCreatingOutputOrRunningBuildTools() throws {
        let scratch = try Scratch("native-review-preflight")
        try scratch.copy(["\(ClientVPNCoreReview.fixtureDirectory)/sources.json"])
        let pins = try ClientVPNCoreReview.sources(root: scratch.url)
        try write("invalid archive", scratch.file(pins[0].archive))
        let output = scratch.url.appendingPathComponent("output")
        #expect(failure { _ = try ClientVPNCoreReview.build(root: scratch.url, archives: scratch.url, output: output) } == "Checksum mismatch for \(pins[0].archive).")
        #expect(!exists(output.path))
    }

    @Test func sourceManifestPinsEveryBuildInput() throws {
        let pins = try ClientVPNCoreReview.sources(root: repository)
        #expect(Set(pins.map(\.id)) == ["openvpn3", "aws-lc", "asio", "lz4", "aws-patches", "cmake"])
        #expect(pins.count == 6)
        for pin in pins {
            #expect(pin.sha256.count == 64 && pin.sha256.allSatisfy { $0.isHexDigit })
            #expect(pin.url.hasPrefix("https://"))
            if let revision = pin.revision {
                #expect(revision.count == 40 && pin.url.hasSuffix(revision))
            }
        }
    }

    @Test func rebasedAWSPatchesReplaceListedAWSPatchesFromTheFixtures() {
        for (original, rebased) in ClientVPNCoreReview.rebasedAWSPatches {
            #expect(ClientVPNCoreReview.awsPatches.contains(original))
            #expect(exists(repository.appendingPathComponent("\(ClientVPNCoreReview.fixtureDirectory)/\(rebased)").path))
        }
    }

    @Test func crossCompilationTargetsEachShippedArchitecture() {
        for architecture in ClientVPNCoreReview.architectures {
            let arguments = ClientVPNCoreReview.cmakeArguments(source: URL(fileURLWithPath: "/tmp/source"), build: URL(fileURLWithPath: "/tmp/build/\(architecture)"), architecture: architecture, options: URL(fileURLWithPath: "/tmp/compile options.cmake"), sdk: "/sdk")
            #expect(arguments.contains("-DCMAKE_OSX_ARCHITECTURES=\(architecture)"))
            #expect(arguments.contains("-DCMAKE_SYSTEM_PROCESSOR=\(architecture)"))
            #expect(arguments.contains("-DENABLE_SOURCE_MODIFICATION=OFF"))
            #expect(arguments.contains("-DBUILD_SHARED_LIBS=OFF"))
            #expect(arguments.contains("-DCMAKE_PROJECT_TOP_LEVEL_INCLUDES=/tmp/compile options.cmake"))
        }
    }

    @Test func cmakePrefixMappingQuotesPathsAsOneLiteralOption() {
        let text = ClientVPNCoreReview.cmakePrefixMap(URL(fileURLWithPath: "/tmp/with spaces ]=] and ${literal}"))
        #expect(text == "add_compile_options([==[-ffile-prefix-map=/tmp/with spaces ]=] and ${literal}=/quorra/native-review]==])\n")
    }
}
