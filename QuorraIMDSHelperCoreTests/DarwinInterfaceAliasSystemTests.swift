import Darwin
import Foundation
import Testing
@testable import QuorraIMDSHelperCore

@Suite("Darwin interface alias system")
struct DarwinInterfaceAliasSystemTests {
    @Test func discoversLoopbackInterface() throws {
        let system = DarwinInterfaceAliasSystem(
            commandRunner: RecordingCommandRunner(),
            expectedOwnerUserID: geteuid()
        )

        #expect(try system.interfaceName(containingIPv4Address: "127.0.0.1") == "lo0")
    }

    @Test func rejectsInvalidIPv4Address() throws {
        let system = DarwinInterfaceAliasSystem(
            commandRunner: RecordingCommandRunner(),
            expectedOwnerUserID: geteuid()
        )

        #expect(throws: DarwinInterfaceAliasSystemError.invalidIPv4Address("invalid")) {
            try system.interfaceName(containingIPv4Address: "invalid")
        }
    }

    @Test func usesFixedIfconfigInvocationForAddingAndRemovingAlias() throws {
        let runner = RecordingCommandRunner()
        let system = DarwinInterfaceAliasSystem(
            commandRunner: runner,
            expectedOwnerUserID: geteuid()
        )

        try system.addIPv4Alias(address: "169.254.169.254", prefixLength: 32, to: "lo0")
        try system.removeIPv4Alias(address: "169.254.169.254", from: "lo0")

        #expect(runner.invocations == [
            .init(
                executableURL: URL(filePath: "/sbin/ifconfig"),
                arguments: ["lo0", "inet", "169.254.169.254/32", "alias"]
            ),
            .init(
                executableURL: URL(filePath: "/sbin/ifconfig"),
                arguments: ["lo0", "inet", "169.254.169.254", "-alias"]
            ),
        ])
    }

    @Test func createsValidatesAndRemovesOwnershipMarker() throws {
        let fixture = try MarkerFixture()
        defer { fixture.remove() }
        let system = DarwinInterfaceAliasSystem(
            commandRunner: RecordingCommandRunner(),
            expectedOwnerUserID: geteuid()
        )

        #expect(try !system.hasOwnershipMarker(at: fixture.markerURL))
        try system.createOwnershipMarker(at: fixture.markerURL)
        #expect(try system.hasOwnershipMarker(at: fixture.markerURL))

        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.markerURL.path
        )
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        try system.removeOwnershipMarker(at: fixture.markerURL)
        #expect(try !system.hasOwnershipMarker(at: fixture.markerURL))
    }

    @Test func rejectsMarkerWithBroadPermissions() throws {
        let fixture = try MarkerFixture()
        defer { fixture.remove() }
        let system = DarwinInterfaceAliasSystem(
            commandRunner: RecordingCommandRunner(),
            expectedOwnerUserID: geteuid()
        )

        try system.createOwnershipMarker(at: fixture.markerURL)
        #expect(chmod(fixture.markerURL.path, mode_t(0o644)) == 0)

        #expect(throws: DarwinInterfaceAliasSystemError.self) {
            try system.hasOwnershipMarker(at: fixture.markerURL)
        }
    }
}

private struct CommandInvocation: Equatable {
    let executableURL: URL
    let arguments: [String]
}

private final class RecordingCommandRunner: SystemCommandRunning {
    private(set) var invocations: [CommandInvocation] = []

    func run(executableURL: URL, arguments: [String]) throws {
        invocations.append(.init(executableURL: executableURL, arguments: arguments))
    }
}

private struct MarkerFixture {
    let directoryURL: URL
    let markerURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        markerURL = directoryURL.appending(path: "ownership", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
