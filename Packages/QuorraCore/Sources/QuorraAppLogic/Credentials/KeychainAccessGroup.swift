import Foundation
import Security

public enum KeychainAccessGroup {
    /// Resolves the runtime keychain access group: `<TeamID>.dev.ajbeck.quorra.shared`.
    ///
    /// Reads the concrete group from the signed `keychain-access-groups` entitlement. Falls back
    /// to the older `AppIdentifierPrefix` Info.plist key, then the suffix-only group name in
    /// unsigned/test contexts.
    public static var shared: String {
        resolve(
            infoDictionary: Bundle.main.infoDictionary ?? [:],
            keychainAccessGroups: currentKeychainAccessGroups()
        )
    }

    public static func resolve(
        infoDictionary: [String: Any],
        keychainAccessGroups: [String]
    ) -> String {
        let suffix = "dev.ajbeck.quorra.shared"
        if let entitledGroup = keychainAccessGroups.first(where: { $0 == suffix || $0.hasSuffix(".\(suffix)") }) {
            return entitledGroup
        }
        if let prefix = infoDictionary["AppIdentifierPrefix"] as? String {
            let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return "\(trimmed).\(suffix)"
        }
        return suffix
    }

    private static func currentKeychainAccessGroups() -> [String] {
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault),
              let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil)
        else {
            return []
        }
        return value as? [String] ?? []
    }
}
