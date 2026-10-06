import Foundation

/// Records written by the sandboxed Quorra also carry a `directoryBookmark`, which decoding ignores.
public struct CLIInstallationRecord: Codable, Equatable, Sendable {
    public let commandPath: String
    public let targetPath: String

    public init(commandPath: String, targetPath: String) {
        self.commandPath = commandPath
        self.targetPath = targetPath
    }
}

public struct CLIInstallationStorage: @unchecked Sendable {
    public static let key = "dev.ajbeck.quorra.cliInstallation"

    public static var `default`: CLIInstallationStorage {
        CLIInstallationStorage(defaults: .standard)
    }

    /// `~/.local/bin`, the per-user command folder the XDG Base Directory spec names.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin", directoryHint: .isDirectory)
    }

    private let defaults: UserDefaults
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func load() -> CLIInstallationRecord? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? decoder.decode(CLIInstallationRecord.self, from: data)
    }

    public func save(_ record: CLIInstallationRecord) {
        guard let data = try? encoder.encode(record) else { return }
        defaults.set(data, forKey: Self.key)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

public enum CLIInstallationLinkStatus: Equatable, Sendable {
    case missing
    case installed
    case repairable
    case conflict
}

public enum CLIInstallationError: LocalizedError, Equatable {
    case destinationConflict(URL)
    case destinationIsNotDirectory(URL)

    public var errorDescription: String? {
        switch self {
        case .destinationConflict(let url):
            "Quorra won’t replace the existing item at \(url.path(percentEncoded: false))."
        case .destinationIsNotDirectory(let url):
            "The selected installation location is not a folder: \(url.path(percentEncoded: false))."
        }
    }
}

public struct CLIInstallationLinkManager {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func status(
        commandURL: URL,
        targetURL: URL,
        previousTargetURL: URL?
    ) -> CLIInstallationLinkStatus {
        guard let existingTarget = symbolicLinkTarget(at: commandURL) else {
            return itemExists(at: commandURL) ? .conflict : .missing
        }

        if pathsMatch(existingTarget, targetURL) {
            return .installed
        }
        if let previousTargetURL, pathsMatch(existingTarget, previousTargetURL) {
            return .repairable
        }
        return .conflict
    }

    public func install(
        commandURL: URL,
        targetURL: URL,
        previousTargetURL: URL?
    ) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: commandURL.deletingLastPathComponent().path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw CLIInstallationError.destinationIsNotDirectory(
                commandURL.deletingLastPathComponent()
            )
        }

        switch status(
            commandURL: commandURL,
            targetURL: targetURL,
            previousTargetURL: previousTargetURL
        ) {
        case .missing:
            try fileManager.createSymbolicLink(at: commandURL, withDestinationURL: targetURL)
        case .installed:
            return
        case .repairable:
            let originalTarget = symbolicLinkTarget(at: commandURL)
            try fileManager.removeItem(at: commandURL)
            do {
                try fileManager.createSymbolicLink(at: commandURL, withDestinationURL: targetURL)
            } catch {
                if let originalTarget {
                    try? fileManager.createSymbolicLink(
                        at: commandURL,
                        withDestinationURL: originalTarget
                    )
                }
                throw error
            }
        case .conflict:
            throw CLIInstallationError.destinationConflict(commandURL)
        }
    }

    public func uninstall(
        commandURL: URL,
        targetURL: URL,
        previousTargetURL: URL?
    ) throws {
        switch status(
            commandURL: commandURL,
            targetURL: targetURL,
            previousTargetURL: previousTargetURL
        ) {
        case .missing:
            return
        case .installed, .repairable:
            try fileManager.removeItem(at: commandURL)
        case .conflict:
            throw CLIInstallationError.destinationConflict(commandURL)
        }
    }

    private func itemExists(at url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private func symbolicLinkTarget(at commandURL: URL) -> URL? {
        guard let path = try? fileManager.destinationOfSymbolicLink(atPath: commandURL.path) else {
            return nil
        }
        if path.hasPrefix("/") {
            return URL(filePath: path)
        }
        return commandURL.deletingLastPathComponent().appending(path: path)
    }

    private func pathsMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }
}
