import AWSConfigINI

public struct ProfileNode: Identifiable, Hashable {
    public let id: String
    public let profile: Profile
    public let origin: Origin

    public nonisolated enum Origin: Hashable {
        case configOnly
        case credentialsOnly
        case both
    }

    public init(id: String, profile: Profile, origin: Origin) {
        self.id = id
        self.profile = profile
        self.origin = origin
    }

    /// The flavor that should receive a write for this profile.
    /// Both `.both` and `.configOnly` write to config because credential-file
    /// fields (access key id / secret) are managed separately via Keychain,
    /// not edited in the config editor in v1.
    public var writeFlavor: FileFlavor {
        switch origin {
        case .configOnly, .both: return .config
        case .credentialsOnly: return .credentials
        }
    }
}
