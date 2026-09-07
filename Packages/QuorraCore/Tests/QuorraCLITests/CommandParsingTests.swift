import Testing
@testable import QuorraCLIKit

@Suite("Command parsing")
struct CommandParsingTests {
    @Test func parsesVersionCommand() throws {
        let command = try QuorraCLI.parseAsRoot(["version"])

        #expect(command is VersionCommand)
    }

    @Test func parsesApplicationLifecycleCommands() throws {
        #expect(try QuorraCLI.parseAsRoot(["start"]) is QuorraStartCommand)
        #expect(try QuorraCLI.parseAsRoot(["stop"]) is QuorraStopCommand)
    }

    @Test func parsesProfileListOptions() throws {
        let command = try QuorraCLI.parseAsRoot([
            "profiles", "list",
            "--config-file", "/tmp/config",
            "--credentials-file", "/tmp/credentials",
            "--format", "json",
        ])
        let list = try #require(command as? ProfileListCommand)

        #expect(list.configFile == "/tmp/config")
        #expect(list.credentialsFile == "/tmp/credentials")
        #expect(list.format == .json)
    }

    @Test func parsesProfileSignInCommand() throws {
        let command = try QuorraCLI.parseAsRoot([
            "profiles", "sign-in", "ac:cp:org_admin",
        ])

        #expect((command as? ProfileSignInCommand)?.profile == "ac:cp:org_admin")
    }

    @Test func rejectsUnknownProfileListFormat() {
        #expect(throws: (any Error).self) {
            try QuorraCLI.parseAsRoot([
                "profiles", "list",
                "--format", "yaml",
            ])
        }
    }

    @Test func parsesIMDSCommands() throws {
        let list = try QuorraCLI.parseAsRoot(["imds", "list", "--format", "json"])
        let status = try QuorraCLI.parseAsRoot(["imds", "status", "default"])
        let start = try QuorraCLI.parseAsRoot(["imds", "start", "Default IMDS Endpoint"])
        let stop = try QuorraCLI.parseAsRoot(["imds", "stop", "default"])
        let switchProfile = try QuorraCLI.parseAsRoot([
            "imds", "switch-profile", "ac:cp:org_admin",
        ])

        #expect((list as? IMDSListCommand)?.format == .json)
        #expect((status as? IMDSStatusCommand)?.endpoint == "default")
        #expect((start as? IMDSStartCommand)?.endpoint == "Default IMDS Endpoint")
        #expect((stop as? IMDSStopCommand)?.endpoint == "default")
        #expect((switchProfile as? IMDSSwitchProfileCommand)?.profile == "ac:cp:org_admin")
        #expect((switchProfile as? IMDSSwitchProfileCommand)?.endpoint == "default")
    }
}
