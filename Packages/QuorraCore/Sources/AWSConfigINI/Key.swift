// Key — a single key-value entry within a Section.
//
// Keys are stored with their name already lowercased (applied during tokenization).
// Typed accessor methods mirror the Go Section.Bool/Int/Float64/Map coercions in sections.go.
// Parser spec §7, §10.

/// A key-value entry within an `AWSConfigINIDocument` section.
///
/// Key names are lowercased at parse time per the AWS Go SDK behavior.
/// Cite: tokenize.go:59 — `strings.ToLower(k)`
/// Parser spec §6.2, §7.1
public struct Key: Sendable, Hashable {
    /// The lowercased key name. May contain spaces, digits, non-ASCII characters.
    /// Parser spec §7.1
    public let name: String

    /// The raw value storage (internal).
    let _value: Value

    /// Leading comments attached to this key. Each element is a raw comment line
    /// (including the leading `#` or `;`).
    public let leadingComments: [String]

    init(name: String, value: Value, leadingComments: [String] = []) {
        self.name = name
        self._value = value
        self.leadingComments = leadingComments
    }

    // MARK: - Typed accessors

    /// The string value, with quotes already stripped via `legacyStrconv`.
    /// For map-typed keys (sub-property parent), returns `""`.
    /// Never returns `nil`; use typed accessors for coercion failures.
    /// Parser spec §10.1
    public var stringValue: String {
        switch _value {
        case .string(let s): return s
        case .map: return ""
        }
    }

    /// Parses the string value as a base-0 `Int64`.
    /// Accepts `0x` (hex), `0o` (octal), `0b` (binary) prefixes; plain decimal integers;
    /// negative values (including `-0xff`, `-0o17`, `-0b1010`). Returns `nil` on any parse
    /// failure or integer overflow.
    ///
    /// Mirrors: strconv.ParseInt(_, 0, 64) — sections.go:136
    /// Parser spec §10.1
    ///
    /// Implementation note: Swift's `Int64(_:radix:)` does not accept a leading '-' sign,
    /// so negative radix-prefixed forms (e.g. `-0xff`) require sign extraction, unsigned
    /// parse of the magnitude, and explicit negation. Plain decimal is handled by `Int64(_:)`
    /// which does accept a leading '-'.
    public func intValue() -> Int64? {
        let s = stringValue
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        let negative = lower.hasPrefix("-")
        let magnitude = negative ? lower.dropFirst() : Substring(lower)
        if magnitude.hasPrefix("0x") {
            guard let abs = Int64(magnitude.dropFirst(2), radix: 16) else { return nil }
            return negative ? -abs : abs
        }
        if magnitude.hasPrefix("0o") {
            guard let abs = Int64(magnitude.dropFirst(2), radix: 8) else { return nil }
            return negative ? -abs : abs
        }
        if magnitude.hasPrefix("0b") {
            guard let abs = Int64(magnitude.dropFirst(2), radix: 2) else { return nil }
            return negative ? -abs : abs
        }
        return Int64(lower)
    }

    /// Parses the string value as a `Double` (IEEE 754 64-bit float).
    /// Supports `1e4`, `1E-4`, `12.3`; rejects hex float notation.
    ///
    /// Mirrors: strconv.ParseFloat(_, 64) — sections.go:147
    /// Parser spec §10.1
    public func doubleValue() -> Double? {
        return Double(stringValue)
    }

    /// Parses the string value as a Boolean.
    /// Strict AWS grammar: case-insensitive `"true"` / `"false"` only.
    /// `"yes"`, `"on"`, `"1"` etc. all return `nil`.
    ///
    /// Mirrors: value.go:79-88 — explicitly does NOT use strconv.ParseBool
    /// Decision D11; parser spec §10.1
    public func boolValue() -> Bool? {
        strictParseBool(stringValue)
    }

    /// Returns the sub-property map if this key's value is a `.map`, otherwise `nil`.
    ///
    /// Mirrors: value.go:56-58 MapValue()
    /// Parser spec §10.1
    public func mapValue() -> [String: String]? {
        if case .map(let m) = _value { return m }
        return nil
    }

    // MARK: - Hashable / Equatable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }

    public static func == (lhs: Key, rhs: Key) -> Bool {
        return lhs.name == rhs.name && lhs._value == rhs._value
    }
}
