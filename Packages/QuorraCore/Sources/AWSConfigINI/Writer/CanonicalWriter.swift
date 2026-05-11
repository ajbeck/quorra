// CanonicalWriter — converts an AWSConfigINIDocument to its canonical string form.
//
// Decisions:
//   D03 — canonical, not byte-exact. Comments and section/key order survive; alignment /
//          separator / quoting are normalized.
//   D14 — separator " = " (space-equals-space).
//   D15 — always double-quote string values.
//   D16 — [default] first; other sections in _sections array order.
//   D17 — BOM re-emitted if document.bomKind != nil.
//
// Plan §9.2 — canonical-write algorithm.

import Foundation

/// Converts `document` to its canonical INI text.
///
/// The output is semantically equivalent to the input but not byte-identical:
/// separator spacing is normalized to ` = `, all string values are double-quoted,
/// and sections are ordered with `[default]` first.
///
/// - Throws: `AWSConfigINIError.encodeError` if any value contains an unrepresentable
///   character (embedded `"` or `\n`). See `ValueEncoding.swift`.
func canonicalWrite(_ document: AWSConfigINIDocument) throws(AWSConfigINIError) -> String {
    let le = document.lineEnding

    // Fast path: empty document.
    // Plan §9.2 — "AWSConfigINIDocument(empty:).write() should return """.
    if document.leadingComments.isEmpty && document._sections.isEmpty {
        return ""
    }

    var out = ""

    // D17: prepend BOM if present.
    // For UTF-8: prepend U+FEFF (BYTE ORDER MARK); its UTF-8 encoding is the three bytes
    // EF BB BF, which is what `write(to:)` will write when it encodes the String as .utf8.
    // For UTF-16-LE/BE: the bytes FF FE / FE FF are not representable in a UTF-8 String,
    // so write(to:) handles those by prepending the raw bytes to the Data before writing.
    // `write() -> String` emits U+FEFF for utf8 and is a no-op for utf16 BOMs.
    if let bom = document.bomKind {
        switch bom {
        case .utf8:
            out += "\u{FEFF}"
        case .utf16LE, .utf16BE:
            // UTF-16 BOMs cannot be represented in a Swift String (UTF-8 code unit sequence).
            // The write(to:) path prepends the raw bytes separately. write() -> String omits them.
            break
        }
    }

    // Document leading comments (before any section header).
    // A blank line is emitted after the block so the parser can distinguish
    // document-level leading comments from the first section's leading comments
    // on round-trip. Without it, a pre-section comment would attach to the
    // first section's leadingComments instead of Document.leadingComments.
    if !document.leadingComments.isEmpty {
        for comment in document.leadingComments {
            out += comment + le
        }
        // Separator blank line — only when sections follow.
        if !document._sections.isEmpty {
            out += le
        }
    }

    // D16: [default] first, then remaining sections in array order.
    let orderedSections: [Section]
    if let defaultIdx = document._sections.firstIndex(where: { $0.name == "default" }) {
        var sections = document._sections
        let defaultSection = sections.remove(at: defaultIdx)
        orderedSections = [defaultSection] + sections
    } else {
        orderedSections = document._sections
    }

    for (sectionIdx, section) in orderedSections.enumerated() {
        // Leading comments for this section.
        for comment in section.leadingComments {
            out += comment + le
        }

        // Section header.
        out += "[\(section.name)]" + le

        // Keys.
        for key in section.keys {
            // Leading comments for this key.
            for comment in key.leadingComments {
                out += comment + le
            }

            switch key._value {
            case .string(let s):
                let encoded = try encodeStringValue(s)
                out += "\(key.name) = \(encoded)" + le

            case .map(let m):
                // Empty parent line, then sorted entries indented two spaces.
                // Sub-property values share `encodeStringValue`'s rules — parser spec §9.1
                // does not introduce any encoding distinction for nested values.
                out += "\(key.name) =" + le
                for (entryKey, entryValue) in m.sorted(by: { $0.key < $1.key }) {
                    let encoded = try encodeStringValue(entryValue)
                    out += "  \(entryKey) = \(encoded)" + le
                }
            }
        }

        // One blank line between sections. Omit the trailing blank after the last section
        // so the file ends with exactly one newline (the last key's line ending), not two.
        if sectionIdx < orderedSections.count - 1 {
            out += le
        }
    }

    return out
}
