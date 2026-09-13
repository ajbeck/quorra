import Foundation

enum QuorraVersion {
    /// Updated with the root release version by Release Please.
    private static let repositoryVersion = "0.6.0" // x-release-please-version

    /// Uses the host app's marketing version for packaged release candidates.
    static var current: String {
        resolve(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            bundledVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String
        )
    }

    static func resolve(bundleIdentifier: String?, bundledVersion: String?) -> String {
        guard bundleIdentifier == "dev.ajbeck.quorra.cli",
              let bundledVersion,
              !bundledVersion.isEmpty else {
            return repositoryVersion
        }
        return bundledVersion
    }
}
