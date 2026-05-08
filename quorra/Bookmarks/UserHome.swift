import Foundation

/// Resolves paths relative to the user's real home directory, independent of
/// App Sandbox. Inside a sandboxed process, `FileManager.homeDirectoryForCurrentUser`
/// and `URL.homeDirectory` both point to `~/Library/Containers/<bundle-id>/Data/`,
/// which is not what we want when we need to reason about paths the user picked
/// through `NSOpenPanel` (which returns real filesystem URLs).
///
/// `NSHomeDirectoryForUser(_:)` with the current username bypasses the sandbox
/// mapping because it resolves via the system's user database rather than the
/// sandbox-aware home-directory APIs.
enum UserHome {
    static var url: URL {
        if let path = NSHomeDirectoryForUser(NSUserName()) {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var awsFolder: URL {
        url.appending(path: ".aws", directoryHint: .isDirectory)
    }
}
