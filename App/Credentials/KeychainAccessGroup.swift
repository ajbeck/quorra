import Foundation

enum KeychainAccessGroup {
    /// Resolves the runtime keychain access group: `<TeamID>.dev.ajbeck.quorra.shared`.
    ///
    /// Reads the team ID from the bundle's `AppIdentifierPrefix` Info.plist key (set at sign time
    /// by Xcode). Falls back to the suffix-only group name in unsigned/test contexts where the
    /// prefix isn't available — this lets unit tests construct a `CredentialsModel` without a
    /// signed bundle, while real app launches use the real shared group.
    static var shared: String {
        let suffix = "dev.ajbeck.quorra.shared"
        if let prefix = Bundle.main.infoDictionary?["AppIdentifierPrefix"] as? String {
            let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return "\(trimmed).\(suffix)"
        }
        return suffix
    }
}
