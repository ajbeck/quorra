import Foundation
import AWSConfigINI

struct ModePreferenceStorage {
    static let key = "dev.ajbeck.quorra.managedMode"

    static let `default` = ModePreferenceStorage(defaults: .standard)

    let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    /// Returns the persisted mode, or `.managed` (the documented default) when absent or unparseable.
    func load() -> ManagedMode {
        guard let raw = defaults.string(forKey: Self.key) else { return .managed }
        switch raw {
        case "managed":  return .managed
        case "readOnly": return .readOnly
        default:         return .managed
        }
    }

    func save(_ mode: ManagedMode) {
        switch mode {
        case .managed:  defaults.set("managed",  forKey: Self.key)
        case .readOnly: defaults.set("readOnly", forKey: Self.key)
        }
    }

    func clear() { defaults.removeObject(forKey: Self.key) }
}
