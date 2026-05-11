// ValueEncoding — canonical on-disk encoding for INI values.
//
// Decision D15: all string values are double-quoted on write.
// Decision D14: separator is " = " (space-equals-space).
// Parser spec §7.4: legacyStrconv strips exactly one matching quote pair; no escape mechanism exists.
// Therefore a raw " embedded in a value cannot survive a write-then-read round-trip and is an error.

/// Encodes a plain string value to its canonical on-disk form.
///
/// Wraps `s` in double quotes per Decision D15. Throws `.encodeError` if `s` contains
/// an unescaped double-quote character or a newline — neither can survive a round-trip
/// through the parser (parser spec §7.4 has no escape mechanism; §3.2 splits on `\n`).
///
/// - Parameter s: The unquoted string value to encode (as stored in `Key.stringValue`).
/// - Returns: The quoted on-disk representation, e.g. `"\"foo-region\""`.
/// - Throws: `AWSConfigINIError.encodeError` for unrepresentable values.
func encodeStringValue(_ s: String) throws(AWSConfigINIError) -> String {
    // Parser spec §7.4: legacyStrconv only strips one matching quote pair — no escape processing.
    // A raw " in the value would alter the quote-pair detection on the next read.
    if s.contains("\"") {
        throw AWSConfigINIError.encodeError("Value contains an unescaped double-quote character and cannot be encoded: \(s.debugDescription). The INI parser has no escape mechanism (parser spec §7.4).")
    }
    // Parser spec §3.2: the parser splits on '\n' — an embedded newline would split the value
    // across two lines and cannot be read back correctly.
    if s.contains("\n") {
        throw AWSConfigINIError.encodeError("Value contains a newline character and cannot be encoded: \(s.debugDescription). INI is line-oriented (parser spec §3.2).")
    }
    return "\"\(s)\""
}
