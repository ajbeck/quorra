// BOM detection and stripping for AWS INI files.
//
// Handles UTF-8 (EF BB BF), UTF-16-LE (FF FE), and UTF-16-BE (FE FF) byte-order marks.
// The BOM kind is persisted on AWSConfigINIDocument.bomKind and re-emitted on write (D17).
//
// Reference: go-ini/ini parser.go:75-106.

import Foundation

/// The byte-order mark found at the start of the input, if any.
public enum BOMKind: Sendable, Hashable {
    /// UTF-8 BOM: EF BB BF
    case utf8
    /// UTF-16 little-endian BOM: FF FE
    case utf16LE
    /// UTF-16 big-endian BOM: FE FF
    case utf16BE

    /// The raw byte sequence for this BOM.
    var bytes: [UInt8] {
        switch self {
        case .utf8:    return [0xEF, 0xBB, 0xBF]
        case .utf16LE: return [0xFF, 0xFE]
        case .utf16BE: return [0xFE, 0xFF]
        }
    }
}

/// Inspects the leading bytes of `data` for a BOM.
/// Returns the detected kind and the byte offset at which content begins.
func detectBOM(in data: Data) -> (kind: BOMKind?, contentStart: Int) {
    // Order matters: UTF-8 (3 bytes) checked first to avoid matching its first two
    // bytes against a hypothetical 2-byte BOM (none of the actual ones collide,
    // but the longer-prefix-first rule is the right discipline).
    for kind in [BOMKind.utf8, .utf16LE, .utf16BE] {
        if data.starts(with: kind.bytes) {
            return (kind, kind.bytes.count)
        }
    }
    return (nil, 0)
}
