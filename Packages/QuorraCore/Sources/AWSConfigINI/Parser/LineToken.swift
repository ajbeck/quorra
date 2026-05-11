// Line token types produced by the tokenizer.
//
// The tokenizer classifies each input line into one of these cases.
// `raw` and `lineIndex` are retained for diagnostics and comment association;
// the canonical writer does NOT echo raw lines (D03).
//
// Mirror of token.go in aws-sdk-go-v2/config/internal/ini.

/// A classified input line produced by `Tokenizer`.
enum LineToken: Sendable {
    /// A section header: `[type name]` or `[name]`.
    /// `type` is empty when there is no whitespace-separated prefix.
    ///
    /// Mirrors: lineTokenProfile (token.go)
    case profile(type: String, name: String, raw: String, lineIndex: Int)

    /// A top-level key-value property. `key` is already lowercased; `value` is legacyStrconv'd.
    ///
    /// Mirrors: lineTokenProperty (token.go)
    case property(key: String, value: String, raw: String, lineIndex: Int)

    /// An indented key-value line. `key` lowercased; `value` legacyStrconv'd;
    /// inline comments are NOT stripped at tokenization time.
    ///
    /// Mirrors: lineTokenSubProperty (token.go)
    case subProperty(key: String, value: String, raw: String, lineIndex: Int)

    /// An indented line with no `=` or `:` separator.
    ///
    /// Mirrors: lineTokenContinuation (token.go)
    case continuation(value: String, raw: String, lineIndex: Int)

    /// A blank line (all whitespace). Retained so the parser can break
    /// pending-comment association when a blank line separates comments
    /// from the next section/key.
    case blank(raw: String, lineIndex: Int)

    /// A full-line comment (first non-whitespace char is `#` or `;`).
    /// Retained so the parser can associate leading comments with sections/keys.
    case fullLineComment(raw: String, lineIndex: Int)

    /// A line that matched no token type (unrecognized).
    /// Retained for accurate warning line numbers.
    case unrecognized(raw: String, lineIndex: Int)
}
