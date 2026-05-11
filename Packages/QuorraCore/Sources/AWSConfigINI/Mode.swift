// ManagedMode — managed vs read-only operating mode.
//
// Decision D02/D03. The mode itself is stored by app/CLI layers in shared Keychain;
// this module enforces it when passed to write operations (M08).

/// The operating mode for writing AWS INI files.
///
/// Decision D02/D03.
public enum ManagedMode: Sendable, Hashable, Codable {
    /// Quorra owns the file and may canonicalize formatting on write.
    case managed
    /// Display only — write operations throw `.readOnly`. (M08)
    case readOnly
}
