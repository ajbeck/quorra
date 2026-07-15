import AWSConfigINI

public struct SSOSessionNode: Identifiable, Hashable {
    /// Verbatim session name as it appears in the config file, e.g. "acme".
    public let id: String
    /// `nil` when the section exists but cannot be decoded (malformed or empty).
    public let session: SSOSession?
    /// Profiles that declare `sso_session = <id>` in either file.
    public var profiles: [ProfileNode]

    public init(id: String, session: SSOSession?, profiles: [ProfileNode]) {
        self.id = id
        self.session = session
        self.profiles = profiles
    }
}
