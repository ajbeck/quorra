// FileFlavor — distinguishes ~/.aws/config from ~/.aws/credentials.
//
// The INI parser itself is flavor-agnostic; flavor informs the AWS overlay
// about how to interpret section names (M07). For M01, flavor is recorded
// on the document but not used in parsing.
// Decision D13; parser spec §15.1.

/// Identifies which AWS shared-config file this document represents.
///
/// The INI syntax is identical for both files; the difference is in how profile
/// section names are interpreted by the AWS overlay layer (M07).
/// Parser spec §15.1
public enum FileFlavor: Sendable, Hashable {
    /// `~/.aws/config` — profiles use the `[profile name]` form; default is `[default]`.
    case config
    /// `~/.aws/credentials` — profiles use the bare `[name]` form; default is `[default]`.
    case credentials
}
