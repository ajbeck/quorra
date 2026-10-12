import Foundation

/// Quorra ran in App Sandbox through 1.1, keeping its store and preferences in its
/// container and App Group container. The unsandboxed app copies them out once and
/// leaves the originals.
public enum SandboxContainer {
    static let bundleIdentifier = "dev.ajbeck.quorra"
    static let preferencesImportedKey = "dev.ajbeck.quorra.sandbox-container-imported"

    public static func dataDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Containers/\(bundleIdentifier)/Data")
    }

    public static func groupDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Group Containers/\(QuorraMetadataSchema.appGroupIdentifier)")
    }

    /// Most recent first: a sandboxed build with `Quorra/Quorra.store`, the App Group store
    /// that 0.5 through 1.1 used, then the container store from before the App Group.
    static func storeURLs(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let applicationSupport = dataDirectory(home: home).appending(path: "Library/Application Support")
        return [
            QuorraMetadataSchema.storeURL(applicationSupportDirectory: applicationSupport),
            groupDirectory(home: home).appending(path: QuorraMetadataSchema.groupStorePath),
            applicationSupport.appending(path: "default.store")
        ]
    }

    /// The container's preferences, then the App Group's, whose "Run in the menu bar only" is current.
    static func preferenceFiles(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [
            dataDirectory(home: home).appending(path: "Library/Preferences/\(bundleIdentifier).plist"),
            groupDirectory(home: home).appending(path: "Library/Preferences/\(QuorraMetadataSchema.appGroupIdentifier).plist")
        ]
    }

    /// Copies the sandboxed app's preferences once. They replace values an older,
    /// unsandboxed development build may have left in the real preferences domain.
    /// If a file exists but can't be read, nothing is marked and the next launch retries.
    public static func importPreferences(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        into defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: preferencesImportedKey) else { return }

        var values: [String: Any] = [:]
        for file in preferenceFiles(home: home) where FileManager.default.fileExists(atPath: file.path) {
            guard let data = try? Data(contentsOf: file),
                  let fileValues = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
            values.merge(fileValues) { _, new in new }
        }
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: preferencesImportedKey)
    }
}
