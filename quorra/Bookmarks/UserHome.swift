import Darwin
import Foundation

/// Resolves paths relative to the user's real home directory, independent of
/// App Sandbox. Inside a sandboxed process, `FileManager.homeDirectoryForCurrentUser`,
/// `URL.homeDirectory`, `NSHomeDirectory()`, and `NSHomeDirectoryForUser(NSUserName())`
/// all return `~/Library/Containers/<bundle-id>/Data/`.
///
/// `getpwuid(getuid())` reads the user record from the system database (via
/// `/etc/passwd`), bypassing the Foundation home-directory APIs that App Sandbox
/// rewrites. This is what we need when we have to reason about paths the user
/// picked through `NSOpenPanel` (which returns real filesystem URLs).
enum UserHome {
    static var url: URL {
        guard let passwd = getpwuid(getuid())?.pointee else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        let path = String(cString: passwd.pw_dir)
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    static var awsFolder: URL {
        url.appending(path: ".aws", directoryHint: .isDirectory)
    }
}
