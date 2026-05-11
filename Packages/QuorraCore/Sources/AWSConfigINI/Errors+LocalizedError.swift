import Foundation

extension AWSConfigINIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "Couldn't find the file at \(url.path(percentEncoded: false))."
        case .ioError(let url, _):
            return "Couldn't read or write \(url.lastPathComponent)."
        case .lockTimeout(let url):
            return "Couldn't get exclusive access to \(url.lastPathComponent). Another process may be holding the lock."
        case .readOnly(let url):
            return "\(url.lastPathComponent) is open in Read Only mode and can't be written."
        case .decodeError(let message):
            return "Couldn't read this profile: \(message)"
        case .encodeError(let message):
            return "This value can't be saved: \(message)"
        case .malformedInput(let message):
            return "Couldn't parse the file: \(message)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .lockTimeout: return "Try again in a moment."
        case .readOnly:    return "Switch to Edit & Manage in Settings to make changes."
        case .ioError(_, let underlying): return underlying.localizedDescription
        default: return nil
        }
    }
}
