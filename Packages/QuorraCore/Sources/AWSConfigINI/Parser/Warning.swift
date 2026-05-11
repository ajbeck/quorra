// Diagnostic warnings produced during parsing.
//
// The Go parser surfaces duplicate-key warnings via Section.Logs (parse.go:55-65).
// We surface all warning categories here as a typed enum per the plan's §5 API contract
// and Decision D06 (silent-tolerance with opt-in warnings).

/// A diagnostic warning produced during INI parsing. Warnings do not prevent
/// parsing from completing; they are collected on `Section.warnings` and `AWSConfigINIDocument.warnings`.
///
/// Mirrors: Go `Section.Logs` (sections.go), plus additional categories for Swift.
public struct Warning: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// A key appeared more than once in the same section. The later value wins.
        /// Cite: parse.go:55-65
        case duplicateKey(name: String)

        /// A property appeared before any section header and was discarded.
        /// Cite: parse.go:51-53 — "LEGACY: don't error on 'global' properties"
        case propertyBeforeSection(line: Int)

        /// A line matched no token type and was discarded.
        /// Cite: tokenize.go:22 — "unrecognized tokens are effectively ignored"
        case unrecognizedLine(line: Int, raw: String)

        /// A value had mismatched or unbalanced quotes (detected if needed in future).
        case malformedQuoting(line: Int)
    }

    public let kind: Kind
    public let line: Int

    init(kind: Kind, line: Int) {
        self.kind = kind
        self.line = line
    }
}
