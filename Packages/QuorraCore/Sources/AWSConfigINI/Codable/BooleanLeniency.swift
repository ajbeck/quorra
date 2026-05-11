// BooleanLeniency — controls how boolean strings are parsed during Codable decode.
//
// Decision D11 (strict grammar):
//   The AWS Go SDK's Section.Bool accepts only case-insensitive "true"/"false".
//   This matches value.go:79-88 which explicitly does NOT use strconv.ParseBool.
//
// go-ini divergence (marshal spec §6.4):
//   go-ini's parseBool (key.go:194-202) accepts 24 spellings including "yes", "no",
//   "on", "off", "1", "0", "y", "n", "YES", "NO", "ON", "OFF" and their capitalizations.
//   .lenient opt-in exposes this broader grammar for non-AWS use cases.
//
// Plan §12.2 task 2.

/// Controls how boolean values are parsed when decoding a `Bool` field.
///
/// The default `.strict` mode matches the AWS Go SDK: only case-insensitive `"true"` or
/// `"false"` are accepted. The `.lenient` mode also accepts `go-ini`'s extended grammar
/// (`"yes"`, `"no"`, `"on"`, `"off"`, `"1"`, `"0"`, `"y"`, `"n"`).
///
/// Decision D11; marshal spec §6.4.
public enum BooleanLeniency: Sendable {
    /// Strict AWS grammar: only case-insensitive `"true"` / `"false"`.
    ///
    /// Matches `value.go:79-88` from the AWS Go SDK. Any other spelling returns `nil`.
    case strict

    /// Lenient grammar: all spellings accepted by `go-ini`'s `parseBool` (`key.go:194-202`).
    ///
    /// Accepts (case-insensitive): `"true"`, `"t"`, `"yes"`, `"y"`, `"on"`, `"1"` → `true`;
    /// `"false"`, `"f"`, `"no"`, `"n"`, `"off"`, `"0"` → `false`.
    /// Documented as opt-in — AWS files should use the strict grammar.
    case lenient
}

/// Parses a string under the AWS Go SDK's strict grammar: case-insensitive
/// `"true"` / `"false"` only. Returns `nil` for any other input.
///
/// Single source of truth for the strict bool grammar — `Key.boolValue()`
/// (M02; parser spec §10.1) and `parseBool(_:leniency:)` both call this.
/// Mirrors `value.go:79-88` from `aws-sdk-go-v2`, which explicitly avoids
/// `strconv.ParseBool` for the same reason.
func strictParseBool(_ s: String) -> Bool? {
    switch s.lowercased() {
    case "true":  return true
    case "false": return false
    default:      return nil
    }
}

/// Parses a string as a `Bool` using the given leniency.
///
/// Returns `nil` if the string does not match the grammar for the chosen mode.
///
/// - Parameters:
///   - s: The raw string value to parse (e.g. `key.stringValue`).
///   - leniency: `.strict` follows the AWS Go SDK; `.lenient` follows go-ini.
func parseBool(_ s: String, leniency: BooleanLeniency) -> Bool? {
    if let strict = strictParseBool(s) { return strict }
    guard leniency == .lenient else { return nil }
    // go-ini parseBool (key.go:194-202) grammar additions over the strict path.
    // Marshal spec §6.4: divergence from AWS parser documented here.
    switch s.lowercased() {
    case "t", "yes", "y", "on",  "1": return true
    case "f", "no",  "n", "off", "0": return false
    default: return nil
    }
}
