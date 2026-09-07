import ArgumentParser

struct ProfilesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profiles",
        abstract: "Inspect AWS profiles.",
        subcommands: [ProfileListCommand.self, ProfileSignInCommand.self]
    )
}
