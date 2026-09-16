import ArgumentParser
import QuorraIPC

struct ProfileListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the profiles managed by the running Quorra app."
    )

    @Option(help: "Output format: \(ProfileListOutputFormat.allCases.map(\.rawValue).joined(separator: ", ")).")
    var format: ProfileListOutputFormat = .table

    func run() throws {
        let profiles: [QuorraProfileRecord] = try IPCCommandClient().payload(operation: .profileList)
        print(try ProfileListRenderer.render(profiles, format: format))
    }
}
