import ArgumentParser
import Foundation
import QuorraIPC

struct IMDSListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List IMDS endpoints managed by the running Quorra app."
    )

    @Option(help: "Output format: \(IMDSOutputFormat.allCases.map(\.rawValue).joined(separator: ", ")).")
    var format: IMDSOutputFormat = .table

    func run() throws {
        let endpoints: [QuorraIMDSEndpointRecord] = try IPCCommandClient().payload(
            operation: .imdsList
        )
        print(try IMDSEndpointRenderer.render(endpoints, format: format))
    }
}

struct IMDSStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the current state of an IMDS endpoint."
    )

    @Argument(help: "Endpoint name, UUID, or ‘default’.")
    var endpoint: String

    @Option(help: "Output format: \(IMDSOutputFormat.allCases.map(\.rawValue).joined(separator: ", ")).")
    var format: IMDSOutputFormat = .table

    func run() throws {
        let record: QuorraIMDSEndpointRecord = try IPCCommandClient().payload(
            operation: .imdsStatus,
            arguments: ["endpoint": endpoint]
        )
        print(try IMDSEndpointRenderer.renderStatus(record, format: format))
    }
}

struct IMDSStartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start an IMDS endpoint."
    )

    @Argument(help: "Endpoint name, UUID, or ‘default’.")
    var endpoint: String

    func run() throws {
        let record: QuorraIMDSEndpointRecord = try IPCCommandClient().payload(
            operation: .imdsStart,
            arguments: ["endpoint": endpoint]
        )
        print(IMDSEndpointRenderer.actionSummary("Started", endpoint: record))
    }
}

struct IMDSStopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop an IMDS endpoint."
    )

    @Argument(help: "Endpoint name, UUID, or ‘default’.")
    var endpoint: String

    func run() throws {
        let record: QuorraIMDSEndpointRecord = try IPCCommandClient().payload(
            operation: .imdsStop,
            arguments: ["endpoint": endpoint]
        )
        print(IMDSEndpointRenderer.actionSummary("Stopped", endpoint: record))
    }
}

struct IMDSSwitchProfileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "switch-profile",
        abstract: "Change the profile served by the Default IMDS Endpoint."
    )

    @Argument(help: "Profile name to serve.")
    var profile: String

    @Option(help: "Endpoint name, UUID, or ‘default’.")
    var endpoint = "default"

    func run() throws {
        let record: QuorraIMDSEndpointRecord = try IPCCommandClient().payload(
            operation: .imdsSwitchProfile,
            arguments: ["endpoint": endpoint, "profile": profile]
        )
        print("\(record.name) now uses \(profile).")
    }
}
