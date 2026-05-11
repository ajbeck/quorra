// String helper functions mirroring aws-sdk-go-v2/config/internal/ini/strings.go.
//
// Each function below cites the corresponding Go function and line number.
// Behaviors here are authoritative per the parser spec §4.4.

import Foundation

/// Space (0x20) + horizontal tab (0x09). The parser's notion of "line space"
/// per `isLineSpace`/`strings.go:57`. Newline-class characters are explicitly
/// excluded since the input is already split on `\n`.
let lineSpaceCharacters = CharacterSet(charactersIn: " \t")

/// Space + tab + carriage return. Used when trimming a whole line that may
/// still carry a trailing `\r` (CRLF input — the parser splits on `\n` only,
/// per parser spec §3.2).
let lineTrimCharacters = CharacterSet(charactersIn: " \t\r")

/// Strips a trailing comment from a profile-header line.
/// Cuts at the first `#`, then cuts the result at the first `;`.
/// No whitespace requirement — any bare `#` or `;` is a comment delimiter here.
///
/// Mirrors: strings.go:7 `trimProfileComment`
/// Parser spec: §4.4, §8.2
func trimProfileComment(_ s: String) -> String {
    let afterHash = s.cutBefore("#")
    let afterSemi = afterHash.cutBefore(";")
    return afterSemi
}

/// Strips a trailing comment from a top-level property value.
/// Cuts at the first occurrence (left-to-right) of `" #"`, `" ;"`, `"\t#"`, `"\t;"`.
/// The comment delimiter MUST be preceded by a space or tab.
///
/// Mirrors: strings.go:13 `trimPropertyComment`
/// Parser spec: §4.4, §8.3
func trimPropertyComment(_ s: String) -> String {
    var r = s
    r = r.cutBefore(" #")
    r = r.cutBefore(" ;")
    r = r.cutBefore("\t#")
    r = r.cutBefore("\t;")
    return r
}

/// Splits a property line into (key, value) using `=` or `:` as separator.
/// Separator selection: use `:` if `=` is absent, OR if both are present and `:` appears first.
/// Both key and value are whitespace-trimmed. Returns `nil` if no separator found.
///
/// Mirrors: strings.go:22 `splitProperty`
/// Parser spec: §4.4, §7.3
func splitProperty(_ s: String) -> (key: String, value: String)? {
    let equalIdx = s.firstIndex(of: "=")
    let colonIdx = s.firstIndex(of: ":")
    let sep: Character
    if let e = equalIdx, let c = colonIdx {
        sep = c < e ? ":" : "="
    } else if equalIdx != nil {
        sep = "="
    } else if colonIdx != nil {
        sep = ":"
    } else {
        return nil
    }
    guard let sepIdx = s.firstIndex(of: sep) else { return nil }
    let key = String(s[s.startIndex..<sepIdx]).trimmingCharacters(in: lineSpaceCharacters)
    let value = String(s[s.index(after: sepIdx)...]).trimmingCharacters(in: lineSpaceCharacters)
    return (key, value)
}

/// Splits a trimmed profile-inner string at the first whitespace run.
/// Returns `(type, name)` where `type` is the part before the first whitespace run
/// and `name` is the part after the run. If no whitespace, returns `("", s)`.
///
/// Mirrors: strings.go:38 `splitProfile`
/// Parser spec: §4.4, §6.1
func splitProfile(_ s: String) -> (type: String, name: String) {
    var firstSpaceStart: String.Index? = nil
    var afterSpaceRun: String.Index? = nil
    var inSpace = false

    for i in s.indices {
        let r = s[i]
        if r == " " || r == "\t" {
            if !inSpace {
                firstSpaceStart = i
                inSpace = true
            }
        } else {
            if inSpace {
                afterSpaceRun = i
                break
            }
        }
    }

    guard let start = firstSpaceStart else {
        // No whitespace — type is blank, name is the whole string
        return ("", s)
    }
    guard let after = afterSpaceRun else {
        // Trailing whitespace run with no following non-space characters
        return ("", "")
    }
    return (String(s[s.startIndex..<start]), String(s[after...]))
}

/// True iff `r` is ASCII space (0x20) or tab (0x09).
/// Newline-class characters are NOT line space; the file is already split on `\n`.
///
/// Mirrors: strings.go:57 `isLineSpace`
func isLineSpace(_ r: Character) -> Bool {
    return r == " " || r == "\t"
}

/// Strips one matching pair of surrounding single or double quotes from `s`.
/// Only acts if both the first and last character are the same quote character.
/// No escape processing inside. Mixed quotes are left untouched.
///
/// Mirrors: strings.go:61,70 `unquote` / `legacyStrconv`
/// Parser spec: §7.4
func legacyStrconv(_ s: String) -> String {
    guard s.count >= 2 else { return s }
    let first = s[s.startIndex]
    let last = s[s.index(before: s.endIndex)]
    if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
        return String(s[s.index(after: s.startIndex)..<s.index(before: s.endIndex)])
    }
    return s
}

/// True iff `s` starts with `[` and ends with `]` (and has length ≥ 2).
///
/// Mirrors: strings.go:83 `isBracketed`
func isBracketed(_ s: String) -> Bool {
    return s.count >= 2 && s.hasPrefix("[") && s.hasSuffix("]")
}

// MARK: - Internal helpers

private extension String {
    /// Returns the prefix before the first occurrence of `delimiter`,
    /// or the whole string if `delimiter` is not found.
    func cutBefore(_ delimiter: String) -> String {
        if let range = self.range(of: delimiter) {
            return String(self[self.startIndex..<range.lowerBound])
        }
        return self
    }
}
