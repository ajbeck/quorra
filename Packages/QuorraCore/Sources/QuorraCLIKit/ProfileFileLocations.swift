import Foundation

struct ProfileFileLocations: Equatable {
    let configURL: URL
    let credentialsURL: URL

    static func resolve(
        configFile: String?,
        credentialsFile: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ProfileFileLocations {
        let awsDirectory = homeDirectory.appending(path: ".aws", directoryHint: .isDirectory)
        return ProfileFileLocations(
            configURL: fileURL(
                explicitPath: configFile,
                environmentPath: environment["AWS_CONFIG_FILE"],
                fallback: awsDirectory.appending(path: "config", directoryHint: .notDirectory)
            ),
            credentialsURL: fileURL(
                explicitPath: credentialsFile,
                environmentPath: environment["AWS_SHARED_CREDENTIALS_FILE"],
                fallback: awsDirectory.appending(path: "credentials", directoryHint: .notDirectory)
            )
        )
    }

    private static func fileURL(
        explicitPath: String?,
        environmentPath: String?,
        fallback: URL
    ) -> URL {
        guard let path = explicitPath ?? environmentPath else { return fallback }
        return URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .notDirectory)
    }
}
