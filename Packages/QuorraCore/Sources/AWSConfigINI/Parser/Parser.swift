// Parser: converts a token stream into an ordered list of (Section, [Warning]) pairs.
//
// This is a stateful single-pass over the LineToken array. State:
//   csection — name of the current open section, or nil if no section opened yet
//   ckey     — lowercased key of the last top-level property in the current section, or nil
//   pendingComments — accumulated full-line comment strings not yet attached to a section/key
//
// The state machine mirrors parse.go in aws-sdk-go-v2/config/internal/ini.
// Parser spec §5.

import Foundation

/// Internal parse result before assembly into `AWSConfigINIDocument`.
struct ParseResult {
    var sections: [ParsedSection] = []
    /// Warnings for properties that appeared before any section.
    var globalWarnings: [Warning] = []
    /// Leading comments before the first section.
    var leadingComments: [String] = []
}

struct ParsedSection {
    var name: String
    var leadingComments: [String]
    var keys: [ParsedKey]
    var keyIndex: [String: Int]
    var warnings: [Warning]
}

struct ParsedKey {
    var name: String
    var value: ParsedValue
    var leadingComments: [String]
}

enum ParsedValue {
    case string(String)
    case map([String: String])
}

func parse(tokens: [LineToken]) -> ParseResult {
    var parser = ParserState()
    for token in tokens {
        parser.handle(token)
    }
    parser.flush()
    return parser.result
}

// MARK: - State machine

private struct ParserState {
    var result = ParseResult()

    // Current open section index in result.sections (-1 = none open)
    var csectionIndex: Int = -1
    // Key name of the last top-level property placed in the current section
    var ckey: String? = nil
    // Comments accumulated since last blank line or section/key attachment
    var pendingComments: [String] = []
    // Whether we've started accumulating content (for leading-doc comments)
    var firstSectionSeen = false

    mutating func handle(_ token: LineToken) {
        switch token {
        case .blank:
            // A blank line breaks comment association. Flush pending comments.
            // Plan §7.2 task 6 sub-bullet: blank line between comments and next
            // section/key flushes pending comments rather than attaching them.
            if firstSectionSeen {
                pendingComments = []
            } else {
                // Before the first section: a blank line flushes pre-section
                // comments into document.leadingComments (they don't belong to
                // any section). This supports the M08 managed-mode header which
                // lives in Document.leadingComments and round-trips through
                // write→read.
                result.leadingComments.append(contentsOf: pendingComments)
                pendingComments = []
            }

        case .fullLineComment(let raw, _):
            // Accumulate into pending; will attach to next section or key.
            // If no section has been seen yet, comments accumulate here until
            // either a blank line (flushed to leadingComments) or the first
            // section header (flushed to section.leadingComments).
            pendingComments.append(raw)

        case .profile(let type, let name, _, let lineIndex):
            handleProfile(type: type, name: name, lineIndex: lineIndex)

        case .property(let key, let value, _, let lineIndex):
            handleProperty(key: key, value: value, lineIndex: lineIndex)

        case .subProperty(let key, let value, _, let lineIndex):
            handleSubProperty(key: key, value: value, lineIndex: lineIndex)

        case .continuation(let value, _, _):
            handleContinuation(value: value)

        case .unrecognized(let raw, let lineIndex):
            // Retained for warning emission; silently discarded from output.
            // Only emit unrecognized warnings if we have an active section.
            if csectionIndex >= 0 {
                result.sections[csectionIndex].warnings.append(
                    Warning(kind: .unrecognizedLine(line: lineIndex, raw: raw), line: lineIndex)
                )
            }
        }
    }

    /// Called after all tokens are processed; flushes any trailing pending comments.
    mutating func flush() {
        // Trailing comments with no following section/key are discarded (not attached).
        pendingComments = []
    }

    // MARK: Token handlers

    /// Cite: parse.go:38-48
    mutating func handleProfile(type: String, name: String, lineIndex: Int) {
        firstSectionSeen = true
        let fullName = type.isEmpty ? name : "\(type) \(name)"
        ckey = nil

        // Check if section already exists — if so, just reset csection (merge)
        if let existing = result.sections.firstIndex(where: { $0.name == fullName }) {
            csectionIndex = existing
            // Flush pending comments (they don't attach to a re-opened section)
            pendingComments = []
            return
        }

        let section = ParsedSection(
            name: fullName,
            leadingComments: pendingComments,
            keys: [],
            keyIndex: [:],
            warnings: []
        )
        result.sections.append(section)
        csectionIndex = result.sections.count - 1
        pendingComments = []
    }

    /// Cite: parse.go:50-71
    mutating func handleProperty(key: String, value: String, lineIndex: Int) {
        guard csectionIndex >= 0 else {
            // Property before any section — discard + warn
            // Cite: parse.go:51-53 — "LEGACY: don't error on 'global' properties"
            result.globalWarnings.append(
                Warning(kind: .propertyBeforeSection(line: lineIndex), line: lineIndex)
            )
            pendingComments = []
            return
        }

        ckey = key
        var section = result.sections[csectionIndex]

        if let existingIdx = section.keyIndex[key] {
            // Duplicate key — warn and overwrite
            // Cite: parse.go:55-65
            section.warnings.append(
                Warning(kind: .duplicateKey(name: key), line: lineIndex)
            )
            section.keys[existingIdx].value = .string(value)
            // Preserve existing leading comments on overwrite
        } else {
            let parsedKey = ParsedKey(
                name: key,
                value: .string(value),
                leadingComments: pendingComments
            )
            section.keyIndex[key] = section.keys.count
            section.keys.append(parsedKey)
        }
        result.sections[csectionIndex] = section
        pendingComments = []
    }

    /// Cite: parse.go:73-96
    mutating func handleSubProperty(key: String, value: String, lineIndex: Int) {
        guard csectionIndex >= 0 else {
            // Sub-property before any section — silently discard
            // Cite: parse.go:75-76 — "LEGACY: don't error on 'global' properties"
            pendingComments = []
            return
        }

        let section = result.sections[csectionIndex]

        // Orphan-promotion rule:
        // If no current key (ckey == nil), OR the parent key's stored string is non-empty,
        // promote this sub-property to a top-level property.
        // Cite: parse.go:78-88
        let shouldPromote: Bool
        if let ck = ckey, let parentIdx = section.keyIndex[ck] {
            if case .string(let parentStr) = section.keys[parentIdx].value {
                shouldPromote = !parentStr.isEmpty
            } else {
                // Parent already has a map value — can still add to it
                shouldPromote = false
            }
        } else {
            // No current key — orphan-promote
            shouldPromote = true
        }

        if shouldPromote {
            // Re-trim property-style comments on the promotion path, then insert as
            // a regular top-level property.
            // Cite: parse.go:83-88
            let promotedValue = trimPropertyComment(value).trimmingCharacters(in: lineSpaceCharacters)
            handleProperty(key: key, value: promotedValue, lineIndex: lineIndex)
            return
        }

        // Attach as a sub-property entry to the parent's map.
        // Comments are NOT re-trimmed here — they survived into `value` from tokenization.
        // Cite: parse.go:90-95
        guard let ck = ckey, let parentIdx = section.keyIndex[ck] else { return }
        var mutableSection = result.sections[csectionIndex]
        switch mutableSection.keys[parentIdx].value {
        case .string:
            // Parent has empty string — replace with map
            mutableSection.keys[parentIdx].value = ParsedValue.map([key: value])
        case .map(var m):
            m[key] = value
            mutableSection.keys[parentIdx].value = ParsedValue.map(m)
        }
        result.sections[csectionIndex] = mutableSection
    }

    /// Cite: parse.go:98-109
    mutating func handleContinuation(value: String) {
        guard let ck = ckey, csectionIndex >= 0 else { return }
        guard let parentIdx = result.sections[csectionIndex].keyIndex[ck] else { return }

        if case .string(let parentStr) = result.sections[csectionIndex].keys[parentIdx].value,
           !parentStr.isEmpty {
            // Only extend if the parent has a non-empty string and no map.
            // Cite: parse.go:104-106
            result.sections[csectionIndex].keys[parentIdx].value = .string(parentStr + "\n" + value)
        }
        // Otherwise: continuation is silently discarded.
        // Cite: parse.go:107-108 — the assignment still happens but value is unmodified
    }
}
