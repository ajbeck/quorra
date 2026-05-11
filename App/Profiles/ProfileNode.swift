import AWSConfigINI

struct ProfileNode: Identifiable, Hashable {
    let id: String
    let profile: Profile
    let origin: Origin

    enum Origin: Hashable {
        case configOnly
        case credentialsOnly
        case both
    }

    /// The flavor that should receive a write for this profile.
    /// Both `.both` and `.configOnly` write to config because credential-file
    /// fields (access key id / secret) are managed separately via Keychain,
    /// not edited in the config editor in v1.
    var writeFlavor: FileFlavor {
        switch origin {
        case .configOnly, .both: return .config
        case .credentialsOnly: return .credentials
        }
    }
}
