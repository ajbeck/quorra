import Foundation

enum AppNavigationRoute: Equatable {
    case mainWindow
    case defaultIMDSEndpoint

    static let externalEventMatchPrefix = "quorra://open"
    static let mainWindowURL = URL(string: "quorra://open/main")!
    static let defaultIMDSEndpointURL = URL(string: "quorra://open/imds/default")!

    init?(url: URL) {
        guard url.scheme?.lowercased() == "quorra",
              url.host?.lowercased() == "open" else { return nil }

        switch url.pathComponents.filter({ $0 != "/" }) {
        case ["main"]:
            self = .mainWindow
        case ["imds", "default"]:
            self = .defaultIMDSEndpoint
        default:
            return nil
        }
    }
}
