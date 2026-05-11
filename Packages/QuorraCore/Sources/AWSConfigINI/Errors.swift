// AWSConfigINIError — all public errors for the module.
//
// Uses Swift 6.2 typed throws (Decision D20).
// M01 only wires .fileNotFound, .ioError, .malformedInput;
// the remaining cases exist for later milestones.

import Foundation

/// All errors that can be thrown by `AWSConfigINI` operations.
///
/// Callers can exhaustively switch over this enum. Decision D20.
public enum AWSConfigINIError: Error, Sendable {
    /// The specified file does not exist.
    case fileNotFound(URL)

    /// A file read or write operation failed.
    case ioError(URL, underlying: any Error)

    /// Acquiring a file lock timed out. (M05)
    case lockTimeout(URL)

    /// Attempted to write while mode is `.readOnly`. (M08)
    case readOnly(URL)

    /// A `Codable` decode operation failed. (M06)
    case decodeError(String)

    /// A `Codable` encode operation failed. (M06)
    case encodeError(String)

    /// A hard parse failure (rare — the parser is almost entirely silent-tolerant). (M01)
    case malformedInput(String)
}
