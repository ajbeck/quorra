import AWSConfigINI
import Foundation
import Observation

/// The AWS folder Quorra reads and, with export on, writes. `~/.aws` unless the user chose another.
public struct AWSFolderStorage: @unchecked Sendable {
    public static let key = "dev.ajbeck.quorra.awsFolderPath"
    static let legacyBookmarkKey = "dev.ajbeck.quorra.awsFolderBookmark"

    public static var `default`: AWSFolderStorage {
        AWSFolderStorage(defaults: .standard)
    }

    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".aws", directoryHint: .isDirectory)
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The chosen folder, or `~/.aws`. A folder the sandboxed Quorra kept as a bookmark becomes a plain path once.
    public func load() -> URL {
        if let path = defaults.string(forKey: Self.key) {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        if let data = defaults.data(forKey: Self.legacyBookmarkKey) {
            defaults.removeObject(forKey: Self.legacyBookmarkKey)
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                save(url)
                return url
            }
        }
        return Self.defaultFolder
    }

    public func save(_ url: URL) {
        defaults.set(url.path(percentEncoded: false), forKey: Self.key)
    }
}

public struct ModePreferenceStorage {
    public static let key = "dev.ajbeck.quorra.managedMode"

    public static var `default`: ModePreferenceStorage {
        ModePreferenceStorage(defaults: .standard)
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Returns the persisted mode, or `.readOnly` when absent: Quorra writes the user's AWS
    /// files only after they turn export on. An unparseable value keeps `.managed`, as before.
    public func load() -> ManagedMode {
        guard let raw = defaults.string(forKey: Self.key) else { return .readOnly }
        switch raw {
        case "managed":
            return .managed
        case "readOnly":
            return .readOnly
        default:
            return .managed
        }
    }

    public func save(_ mode: ManagedMode) {
        switch mode {
        case .managed:
            defaults.set("managed", forKey: Self.key)
        case .readOnly:
            defaults.set("readOnly", forKey: Self.key)
        }
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

@Observable
@MainActor
public final class AppModel {
    public private(set) var folderURL: URL
    public private(set) var mode: ManagedMode

    @ObservationIgnored private let folderStorage: AWSFolderStorage
    @ObservationIgnored private let modeStorage: ModePreferenceStorage

    public init(
        folderStorage: AWSFolderStorage = .default,
        modeStorage: ModePreferenceStorage = .default
    ) {
        self.folderStorage = folderStorage
        self.modeStorage = modeStorage
        folderURL = folderStorage.load()
        mode = modeStorage.load()
    }

    /// For previews and tests: starts at `folderURL` without reading stored preferences.
    public init(
        folderURL: URL,
        mode: ManagedMode = .readOnly,
        folderStorage: AWSFolderStorage = .default,
        modeStorage: ModePreferenceStorage = .default
    ) {
        self.folderStorage = folderStorage
        self.modeStorage = modeStorage
        self.folderURL = folderURL
        self.mode = mode
    }

    public func chooseFolder(_ url: URL) {
        folderStorage.save(url)
        folderURL = url
    }

    /// Persists before publishing so the worst-case inconsistency is
    /// "stale observer / correct disk" rather than "updated observer / lost disk write".
    public func setMode(_ newMode: ManagedMode) async {
        modeStorage.save(newMode)
        mode = newMode
    }
}
