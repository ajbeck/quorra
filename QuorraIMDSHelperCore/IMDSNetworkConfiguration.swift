import Foundation

public enum IMDSNetworkConfiguration {
    public static let interfaceName = "lo0"
    public static let publicAddress = "169.254.169.254"
    public static let publicPrefixLength = 32
    public static let publicPort = 80
    public static let backendAddress = "127.0.0.1"
    public static let backendPort = 7_114

    public static let ownershipMarkerURL = URL(
        filePath: "/var/run/dev.ajbeck.quorra.imds-helper.alias",
        directoryHint: .notDirectory
    )
}
