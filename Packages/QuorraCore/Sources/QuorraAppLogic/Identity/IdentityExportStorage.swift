import Foundation

/// Remembers which sessions and profiles the last export wrote, so a later export can remove what
/// Quorra deleted since.
public struct IdentityExportStorage {
    public static let key = "dev.ajbeck.quorra.identityExportRecord"

    public static var `default`: IdentityExportStorage {
        IdentityExportStorage(defaults: .standard)
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func load() -> IdentityExportRecord {
        guard let data = defaults.data(forKey: Self.key),
              let record = try? JSONDecoder().decode(IdentityExportRecord.self, from: data) else {
            return .empty
        }
        return record
    }

    public func save(_ record: IdentityExportRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.key)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
