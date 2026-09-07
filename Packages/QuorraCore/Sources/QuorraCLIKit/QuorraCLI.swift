import ArgumentParser

struct QuorraCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quorra",
        abstract: "Work with Quorra profiles and services from the command line.",
        version: QuorraVersion.current,
        subcommands: [
            VersionCommand.self,
            ProfilesCommand.self,
            IMDSCommand.self,
            QuorraStartCommand.self,
            QuorraStopCommand.self,
        ]
    )
}

public enum QuorraCLIEntryPoint {
    public static func main() async {
        await QuorraCLI.main()
    }
}
