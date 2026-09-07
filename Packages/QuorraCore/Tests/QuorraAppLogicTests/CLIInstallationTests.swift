import Foundation
import QuorraAppLogic
import Testing

@Suite(.serialized)
struct CLIInstallationTests {
    @Test func installsAndRemovesOwnedLink() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        try fixture.manager.install(
            commandURL: fixture.commandURL,
            targetURL: fixture.targetURL,
            previousTargetURL: nil
        )

        #expect(fixture.manager.status(
            commandURL: fixture.commandURL,
            targetURL: fixture.targetURL,
            previousTargetURL: nil
        ) == .installed)

        try fixture.manager.uninstall(
            commandURL: fixture.commandURL,
            targetURL: fixture.targetURL,
            previousTargetURL: nil
        )
        #expect(!FileManager.default.fileExists(atPath: fixture.commandURL.path))
    }

    @Test func repairsLinkOwnedByPreviousAppLocation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let previousTargetURL = fixture.rootURL.appending(path: "old-quorra-cli")
        try Data().write(to: previousTargetURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.commandURL,
            withDestinationURL: previousTargetURL
        )

        #expect(fixture.manager.status(
            commandURL: fixture.commandURL,
            targetURL: fixture.targetURL,
            previousTargetURL: previousTargetURL
        ) == .repairable)

        try fixture.manager.install(
            commandURL: fixture.commandURL,
            targetURL: fixture.targetURL,
            previousTargetURL: previousTargetURL
        )
        #expect(fixture.manager.status(
            commandURL: fixture.commandURL,
            targetURL: fixture.targetURL,
            previousTargetURL: previousTargetURL
        ) == .installed)
    }

    @Test func neverOverwritesUnrelatedFile() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = Data("leave me alone".utf8)
        try original.write(to: fixture.commandURL)

        #expect(fixture.manager.status(
            commandURL: fixture.commandURL,
            targetURL: fixture.targetURL,
            previousTargetURL: nil
        ) == .conflict)
        #expect(throws: CLIInstallationError.destinationConflict(fixture.commandURL)) {
            try fixture.manager.install(
                commandURL: fixture.commandURL,
                targetURL: fixture.targetURL,
                previousTargetURL: nil
            )
        }
        #expect(try Data(contentsOf: fixture.commandURL) == original)
    }

    @Test func neverRemovesUnrelatedLink() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let unrelatedTarget = fixture.rootURL.appending(path: "other-tool")
        try Data().write(to: unrelatedTarget)
        try FileManager.default.createSymbolicLink(
            at: fixture.commandURL,
            withDestinationURL: unrelatedTarget
        )

        #expect(throws: CLIInstallationError.destinationConflict(fixture.commandURL)) {
            try fixture.manager.uninstall(
                commandURL: fixture.commandURL,
                targetURL: fixture.targetURL,
                previousTargetURL: nil
            )
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: fixture.commandURL.path
        ) == unrelatedTarget.path)
    }

    @Test func detectsMissingLinkAsRepairableStateForController() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        #expect(fixture.manager.status(
            commandURL: fixture.commandURL,
            targetURL: fixture.targetURL,
            previousTargetURL: fixture.targetURL
        ) == .missing)
    }
}

private struct Fixture {
    let rootURL: URL
    let binURL: URL
    let commandURL: URL
    let targetURL: URL
    let manager = CLIInstallationLinkManager()

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "quorra-cli-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        binURL = rootURL.appending(path: "bin", directoryHint: .isDirectory)
        commandURL = binURL.appending(path: "quorra")
        targetURL = rootURL.appending(path: "quorra-cli")
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        try Data().write(to: targetURL)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
