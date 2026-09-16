import Foundation

/// Remembers that the one-time import of SSO sessions and profiles from the AWS folder has run.
public struct IdentityImportStorage {
    public static let key = "dev.ajbeck.quorra.identityImportCompleted"

    public static var `default`: IdentityImportStorage {
        IdentityImportStorage(defaults: .standard)
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var hasCompleted: Bool {
        defaults.bool(forKey: Self.key)
    }

    public func markCompleted() {
        defaults.set(true, forKey: Self.key)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
