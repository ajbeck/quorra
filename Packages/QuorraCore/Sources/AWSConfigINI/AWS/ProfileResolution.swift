// ProfileResolution.swift — FileFlavor helper for AWS profile section name projection.
//
// The INI parser stores section names verbatim. The AWS docs define an asymmetry
// between the two shared-config files:
//
//   ~/.aws/config       → default: "[default]"  others: "[profile NAME]"
//   ~/.aws/credentials  → default: "[default]"  others: "[NAME]"
//
// This extension encapsulates that mapping so every call site
// (Document, decoder, encoder) computes the same section name.
//
// Plan §13.2 task 1; parser spec §15.1; AWS docs cli-configure-files-format-profile.

/// AWS profile section-name projection.
public extension FileFlavor {
    /// Returns the INI section name that holds the given profile.
    ///
    /// `"default"` maps to `"default"` regardless of flavor — both files use
    /// the bare `[default]` header for the default profile.
    ///
    /// For any other name:
    /// - `.config` → `"profile \(name)"` (e.g. `"profile dev"`)
    /// - `.credentials` → `"\(name)"` (e.g. `"dev"`)
    ///
    /// Parser spec §15.1; AWS docs cli-configure-files-format-profile.
    func profileSectionName(for name: String) -> String {
        guard name != "default" else { return "default" }
        switch self {
        case .config:
            return "profile \(name)"
        case .credentials:
            return name
        }
    }
}
