// Tokenizer: classifies each input line into a LineToken.
//
// Classification order follows tokenize.go in aws-sdk-go-v2/config/internal/ini exactly.
// Unlike the Go tokenizer, this one emits ALL lines including blanks, comments, and
// unrecognized lines so the parser can associate comments and emit accurate warnings.
//
// Parser spec §4.1–§4.5.

import Foundation

/// Space + tab + LF + CR. Used only for the blank-line predicate where any
/// whitespace-class byte counts.
private let blankLineCharacters = CharacterSet(charactersIn: " \t\n\r")

/// Classifies `content` (already BOM-stripped) into an ordered array of `LineToken` values.
/// Lines are split on `\n` only — `\r` is left in place per the Go parser behavior.
///
/// Cite: ini.go:49 — `lines := strings.Split(string(contents), "\n")`
/// Parser spec §3.2
func tokenize(_ content: String) -> [LineToken] {
    let lines = content.components(separatedBy: "\n")
    var tokens: [LineToken] = []
    tokens.reserveCapacity(lines.count)

    for (index, line) in lines.enumerated() {
        tokens.append(classifyLine(line, at: index))
    }
    return tokens
}

/// Classifies a single line into its `LineToken` case.
private func classifyLine(_ line: String, at index: Int) -> LineToken {
    // Pre-classification: blank line
    if line.trimmingCharacters(in: blankLineCharacters).isEmpty {
        return .blank(raw: line, lineIndex: index)
    }

    // Pre-classification: full-line comment
    // Cite: tokenize.go:27-30
    if isLineComment(line) {
        return .fullLineComment(raw: line, lineIndex: index)
    }

    // Classification order 1: profile header
    // asProfile: TrimSpace(trimProfileComment(line)) starts with '[' and ends with ']'
    // Leading whitespace IS allowed before '['.
    // Cite: tokenize.go:32-44
    if let (type, name) = tryAsProfile(line) {
        return .profile(type: type, name: name, raw: line, lineIndex: index)
    }

    // Classification order 2: top-level property
    // First character must NOT be line-space.
    // Cite: tokenize.go:46-62
    if let (key, value) = tryAsProperty(line) {
        return .property(key: key, value: value, raw: line, lineIndex: index)
    }

    // Classification order 3: indented sub-property
    // First character must be line-space; line must split successfully.
    // Comments are intentionally NOT stripped here — they survive into the value.
    // Cite: tokenize.go:64-80
    if let (key, value) = tryAsSubProperty(line) {
        return .subProperty(key: key, value: value, raw: line, lineIndex: index)
    }

    // Classification order 4: continuation
    // First character must be line-space; splitProperty returns nil.
    // Cite: tokenize.go:82-92
    if let value = tryAsContinuation(line) {
        return .continuation(value: value, raw: line, lineIndex: index)
    }

    // Unrecognized — silently dropped by Go parser but we retain for warnings.
    // Cite: tokenize.go:22 — "// unrecognized tokens are effectively ignored"
    return .unrecognized(raw: line, lineIndex: index)
}

// MARK: - Classification helpers

/// True iff the line is a full-line comment (first non-whitespace char is `#` or `;`).
/// Cite: tokenize.go:27-30
private func isLineComment(_ line: String) -> Bool {
    let trimmed = line.drop(while: { isLineSpace($0) })
    return trimmed.hasPrefix("#") || trimmed.hasPrefix(";")
}

/// Attempts to parse a profile header. Returns `(type, name)` on success.
/// Cite: tokenize.go:32-44
private func tryAsProfile(_ line: String) -> (type: String, name: String)? {
    let trimmed = trimProfileComment(line).trimmingCharacters(in: lineTrimCharacters)
    guard isBracketed(trimmed) else { return nil }
    let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: lineSpaceCharacters)
    let (type, name) = splitProfile(inner)
    return (type, name)
}

/// Attempts to parse a top-level property. First char must not be line-space.
/// Cite: tokenize.go:46-62
private func tryAsProperty(_ line: String) -> (key: String, value: String)? {
    guard let first = line.first, !isLineSpace(first) else { return nil }
    let trimmed = trimPropertyComment(line).trimmingCharacters(in: lineTrimCharacters)
    guard let (k, v) = splitProperty(trimmed) else { return nil }
    return (k.lowercased(), legacyStrconv(v))
}

/// Attempts to parse an indented sub-property. First char must be line-space.
/// Comments are NOT stripped (they remain in the value).
/// Cite: tokenize.go:64-80
private func tryAsSubProperty(_ line: String) -> (key: String, value: String)? {
    guard let first = line.first, isLineSpace(first) else { return nil }
    let trimmed = String(line.drop(while: { isLineSpace($0) }))
    guard let (k, v) = splitProperty(trimmed) else { return nil }
    return (k.lowercased(), legacyStrconv(v))
}

/// Attempts to parse a continuation. First char must be line-space; no separator found.
/// Cite: tokenize.go:82-92
private func tryAsContinuation(_ line: String) -> String? {
    guard let first = line.first, isLineSpace(first) else { return nil }
    let trimmed = String(line.drop(while: { isLineSpace($0) }))
    // Only a continuation if splitProperty fails
    if splitProperty(trimmed) != nil { return nil }
    return trimmed
}
