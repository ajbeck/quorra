import Foundation

public struct QuorraIPCEndpoint: Equatable, Sendable {
    public static let socketFileName = "ipc-v1.sock"

    public let socketURL: URL

    public init(socketURL: URL) {
        self.socketURL = socketURL.standardizedFileURL
    }

    public static func shared(fileManager: FileManager = .default) throws -> Self {
        if let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: QuorraIPCProtocol.appGroupIdentifier
        ) {
            return Self(socketURL: containerURL.appendingPathComponent(socketFileName))
        }

        // A directly invoked, nonsandboxed macOS helper can return nil here even
        // with the App Group entitlement. Apple documents this location for
        // team-prefixed macOS groups. Never create it from the helper: the
        // sandboxed app must have established the system-owned container first.
        if let containerURL = fallbackContainerURL(
            fileManager: fileManager,
            homeDirectory: fileManager.homeDirectoryForCurrentUser
        ) {
            return Self(socketURL: containerURL.appendingPathComponent(socketFileName))
        }

        throw QuorraIPCEndpointError.appGroupUnavailable
    }

    static func fallbackContainerURL(
        fileManager: FileManager,
        homeDirectory: URL
    ) -> URL? {
        let containerURL = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Group Containers", isDirectory: true)
            .appendingPathComponent(QuorraIPCProtocol.appGroupIdentifier, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: containerURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return containerURL
    }
}

public enum QuorraIPCEndpointError: LocalizedError, Equatable {
    case appGroupUnavailable

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "Quorra’s shared command-line container is unavailable. Reinstall Quorra and its command-line tool."
        }
    }
}
