import Foundation

/// All errors that can be thrown by `AWSConfigINI` operations.
///
/// Uses Swift 6.2 typed throws so callers can `catch` exhaustively.
public enum AWSConfigINIError: Error, Sendable {
    /// The specified file does not exist.
    case fileNotFound(URL)

    /// A file read or write operation failed.
    case ioError(URL, underlying: any Error)

    /// Acquiring a file lock timed out.
    case lockTimeout(URL)

    /// Attempted to write while mode is `.readOnly`.
    case readOnly(URL)

    /// A `Codable` decode operation failed.
    case decodeError(String)

    /// A `Codable` encode operation failed.
    case encodeError(String)

    /// A hard parse failure (rare — the parser is almost entirely silent-tolerant).
    case malformedInput(String)
}
