// ValueEncoding — canonical on-disk encoding for INI values.
//
// Decision D15 (revised 16 September 2026): string values are written bare, never quoted.
// The AWS SDKs and Tools Reference defines an entry as `setting-name=value` with no quoting
// (https://docs.aws.amazon.com/sdkref/latest/guide/file-format.html), `aws configure set`
// writes bare values, and the AWS CLI reads a quoted value with its quotes included, which
// breaks region and sso_session lookups. The parser still strips one matching quote pair
// (legacyStrconv), so files written before this revision keep reading correctly.
// Decision D14: separator is " = " (space-equals-space).
// Parser spec §7.4: legacyStrconv strips exactly one matching quote pair; no escape mechanism exists.
// Therefore a raw " embedded in a value cannot survive a write-then-read round-trip and is an error.

/// Encodes a plain string value to its canonical on-disk form.
///
/// Returns `s` unchanged per Decision D15 (revised). Throws `.encodeError` if `s` contains
/// a double-quote character or a newline — neither can survive a round-trip through the
/// parser (parser spec §7.4 strips a matching quote pair; §3.2 splits on `\n`).
///
/// - Parameter s: The string value to encode (as stored in `Key.stringValue`).
/// - Returns: The on-disk representation, which is `s` itself, e.g. `foo-region`.
/// - Throws: `AWSConfigINIError.encodeError` for unrepresentable values.
func encodeStringValue(_ s: String) throws(AWSConfigINIError) -> String {
    // Parser spec §7.4: legacyStrconv strips one matching quote pair — no escape processing.
    // A value that begins and ends with " would lose those quotes on the next read.
    if s.contains("\"") {
        throw AWSConfigINIError.encodeError("Value contains an unescaped double-quote character and cannot be encoded: \(s.debugDescription). The INI parser has no escape mechanism (parser spec §7.4).")
    }
    // Parser spec §3.2: the parser splits on '\n' — an embedded newline would split the value
    // across two lines and cannot be read back correctly.
    if s.contains("\n") {
        throw AWSConfigINIError.encodeError("Value contains a newline character and cannot be encoded: \(s.debugDescription). INI is line-oriented (parser spec §3.2).")
    }
    return s
}
