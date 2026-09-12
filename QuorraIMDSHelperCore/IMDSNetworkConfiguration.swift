import Foundation

enum IMDSNetworkConfiguration {
    static let interfaceName = "lo0"
    static let publicAddress = "169.254.169.254"
    static let publicPrefixLength = 32
    static let publicPort = 80
    static let backendAddress = "127.0.0.1"
    static let backendPort = 7_114

    static let ownershipMarkerURL = URL(
        filePath: "/var/run/dev.ajbeck.quorra.imds-helper.alias",
        directoryHint: .notDirectory
    )
}
