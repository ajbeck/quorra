import ArgumentParser

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print the Quorra version."
    )

    func run() {
        print(QuorraVersion.current)
    }
}
