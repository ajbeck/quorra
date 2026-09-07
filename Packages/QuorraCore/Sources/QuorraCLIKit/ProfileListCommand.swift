import ArgumentParser
import QuorraProfiles

struct ProfileListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List profiles from the shared AWS configuration files."
    )

    @Option(help: "Path to the AWS config file.")
    var configFile: String?

    @Option(help: "Path to the AWS shared credentials file.")
    var credentialsFile: String?

    @Option(help: "Output format: \(ProfileListOutputFormat.allCases.map(\.rawValue).joined(separator: ", ")).")
    var format: ProfileListOutputFormat = .table

    func run() throws {
        let locations = ProfileFileLocations.resolve(
            configFile: configFile,
            credentialsFile: credentialsFile
        )
        let catalog = try ProfileCatalogLoader.load(
            configURL: locations.configURL,
            credentialsURL: locations.credentialsURL
        )
        let output = try ProfileListRenderer.render(catalog.groups.flatProfiles, format: format)
        print(output)
    }
}
