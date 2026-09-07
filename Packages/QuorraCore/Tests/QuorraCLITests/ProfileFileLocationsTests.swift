import Foundation
import Testing
@testable import QuorraCLIKit

@Suite("ProfileFileLocations")
struct ProfileFileLocationsTests {
    @Test func defaultsToAWSFilesInHomeDirectory() {
        let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)

        let locations = ProfileFileLocations.resolve(
            configFile: nil,
            credentialsFile: nil,
            environment: [:],
            homeDirectory: home
        )

        #expect(locations.configURL.path == "/Users/example/.aws/config")
        #expect(locations.credentialsURL.path == "/Users/example/.aws/credentials")
    }

    @Test func environmentOverridesDefaultLocations() {
        let locations = ProfileFileLocations.resolve(
            configFile: nil,
            credentialsFile: nil,
            environment: [
                "AWS_CONFIG_FILE": "/tmp/aws-config",
                "AWS_SHARED_CREDENTIALS_FILE": "/tmp/aws-credentials",
            ],
            homeDirectory: URL(filePath: "/Users/example", directoryHint: .isDirectory)
        )

        #expect(locations.configURL.path == "/tmp/aws-config")
        #expect(locations.credentialsURL.path == "/tmp/aws-credentials")
    }

    @Test func explicitOptionsOverrideEnvironmentLocations() {
        let locations = ProfileFileLocations.resolve(
            configFile: "/tmp/explicit-config",
            credentialsFile: "/tmp/explicit-credentials",
            environment: [
                "AWS_CONFIG_FILE": "/tmp/environment-config",
                "AWS_SHARED_CREDENTIALS_FILE": "/tmp/environment-credentials",
            ],
            homeDirectory: URL(filePath: "/Users/example", directoryHint: .isDirectory)
        )

        #expect(locations.configURL.path == "/tmp/explicit-config")
        #expect(locations.credentialsURL.path == "/tmp/explicit-credentials")
    }
}
