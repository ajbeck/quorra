import AWSConfigINI

struct SSOSessionNode: Identifiable, Hashable {
    /// Verbatim session name as it appears in the config file, e.g. "acme".
    let id: String
    /// `nil` when the section exists but cannot be decoded (malformed or empty).
    let session: SSOSession?
    /// Profiles that declare `sso_session = <id>` in either file.
    var profiles: [ProfileNode]
}
