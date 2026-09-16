import Foundation

/// A shell the Credentials card can write an environment snippet for.
///
/// `script(...)` is exactly the text the card copies: one assignment per line for the access key,
/// the secret, the session token, `AWS_REGION`, and `AWS_DEFAULT_REGION`, each value in the
/// shell's literal single-quoted form so no character of a credential is interpreted.
public enum CredentialShell: String, CaseIterable, Identifiable, Sendable {
    case bash
    case zsh
    case fish
    case powershell

    public var id: String { rawValue }

    /// Picker label: the binary's name.
    public var label: String { rawValue }

    /// The snippet for `region` and the three credential values, one assignment per line.
    public func script(accessKeyId: String, secretAccessKey: String, sessionToken: String, region: String) -> String {
        [
            ("AWS_ACCESS_KEY_ID", accessKeyId),
            ("AWS_SECRET_ACCESS_KEY", secretAccessKey),
            ("AWS_SESSION_TOKEN", sessionToken),
            ("AWS_REGION", region),
            ("AWS_DEFAULT_REGION", region),
        ]
        .map { assignment(name: $0.0, value: $0.1) }
        .joined(separator: "\n")
    }

    private func assignment(name: String, value: String) -> String {
        switch self {
        case .bash, .zsh:
            // POSIX single quotes take every character literally; a quote itself is written '\''.
            return "export \(name)='\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
        case .fish:
            // fish, "Quotes": "The only meaningful escape sequences in single quotes are \', which
            // escapes a single quote and \\, which escapes the backslash symbol." `set -gx` is the
            // documented global, exported form (https://fishshell.com/docs/current/language.html).
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            return "set -gx \(name) '\(escaped)'"
        case .powershell:
            // about_Quoting_Rules: a single-quoted string is verbatim, and "To include a single
            // quotation mark in a single-quoted string, use a second consecutive single quote."
            // about_Environment_Variables: `$Env:<variable-name> = "<new-value>"` sets the variable
            // for the current session.
            return "$env:\(name) = '\(value.replacingOccurrences(of: "'", with: "''"))'"
        }
    }
}
