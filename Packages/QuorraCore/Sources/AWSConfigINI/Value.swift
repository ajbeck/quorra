// Internal Value enum — the discriminated union stored per key.
//
// The Go equivalent is `type Value struct { str string; mp map[string]string }` (value.go).
// We drop the `Type` field (ValueType) because the Go parser never sets it — it's dead code.
// Parser spec §10, §16 open question #5.

/// Internal storage for a parsed key value.
/// Either a plain string (after legacyStrconv), or a map of sub-property entries.
enum Value: Sendable {
    /// A scalar string value, already legacyStrconv'd (quotes stripped).
    /// The empty string is a valid stored value (e.g. `aws_access_key_id =`).
    case string(String)

    /// A map of sub-property entries built from indented `k=v` lines beneath an
    /// empty parent. Corresponds to Go's `Value.mp`. Sub-property values retain
    /// inline comments because comments are not trimmed at tokenization time for
    /// indented lines. Parser spec §8.4.
    case map([String: String])
}

extension Value: Equatable {
    static func == (lhs: Value, rhs: Value) -> Bool {
        switch (lhs, rhs) {
        case (.string(let l), .string(let r)): return l == r
        case (.map(let l), .map(let r)): return l == r
        default: return false
        }
    }
}
