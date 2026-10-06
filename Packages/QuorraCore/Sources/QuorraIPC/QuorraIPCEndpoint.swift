import Foundation

public struct QuorraIPCEndpoint: Equatable, Sendable {
    public static let socketFileName = "ipc-v1.sock"

    public let socketURL: URL

    public init(socketURL: URL) {
        self.socketURL = socketURL.standardizedFileURL
    }

    /// `~/Library/Application Support/Quorra/ipc-v1.sock`, beside Quorra's data store.
    /// Neither the app nor the CLI is sandboxed, so both resolve the same folder.
    public static func shared() -> Self {
        Self(socketURL: URL.applicationSupportDirectory.appending(path: "Quorra/\(socketFileName)"))
    }
}
