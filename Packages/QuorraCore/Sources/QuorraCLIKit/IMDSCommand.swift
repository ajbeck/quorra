import ArgumentParser

struct IMDSCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "imds",
        abstract: "Inspect and control Quorra IMDS endpoints.",
        subcommands: [
            IMDSListCommand.self,
            IMDSStatusCommand.self,
            IMDSStartCommand.self,
            IMDSStopCommand.self,
            IMDSSwitchProfileCommand.self,
        ]
    )
}
