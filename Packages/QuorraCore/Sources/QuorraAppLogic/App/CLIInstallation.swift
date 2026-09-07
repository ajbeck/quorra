import Foundation

public struct CLIInstallationRecord: Codable, Equatable, Sendable {
    public let directoryBookmark: Data
    public let commandPath: String
    public let targetPath: String

    public init(directoryBookmark: Data, commandPath: String, targetPath: String) {
        self.directoryBookmark = directoryBookmark
        self.commandPath = commandPath
        self.targetPath = targetPath
    }
}

public struct CLIInstallationStorage: @unchecked Sendable {
    public static let key = "dev.ajbeck.quorra.cliInstallation"

    public static var `default`: CLIInstallationStorage {
        CLIInstallationStorage(defaults: .standard)
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

    public func makeBookmark(for directoryURL: URL) throws -> Data {
        try directoryURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
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
