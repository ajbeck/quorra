import AppKit
import Foundation

private enum LoginItemConfiguration {
    /// The main app's preferences domain; the helper is not sandboxed, so it can read it.
    static let appIdentifier = "dev.ajbeck.quorra"
    static let menuBarOnlyKey = "dev.ajbeck.quorra.menu-bar-only"
}

let helperURL = Bundle.main.bundleURL.standardizedFileURL
let mainAppURL = (0..<4).reduce(helperURL) { url, _ in
    url.deletingLastPathComponent()
}

guard mainAppURL.pathExtension == "app" else {
    exit(EXIT_FAILURE)
}

let menuBarOnly = UserDefaults(
    suiteName: LoginItemConfiguration.appIdentifier
)?.bool(forKey: LoginItemConfiguration.menuBarOnlyKey) ?? false
let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = !menuBarOnly
configuration.addsToRecentItems = false
configuration.hides = menuBarOnly

NSWorkspace.shared.openApplication(
    at: mainAppURL,
    configuration: configuration
) { _, error in
    exit(error == nil ? EXIT_SUCCESS : EXIT_FAILURE)
}

RunLoop.main.run()
