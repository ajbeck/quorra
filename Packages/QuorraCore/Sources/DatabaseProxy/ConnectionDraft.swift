import Foundation

nonisolated enum DatabaseEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case postgresql
    case mysql

    var id: String { rawValue }
    var displayName: String { self == .postgresql ? "PostgreSQL" : "MySQL" }
    var defaultPort: Int { self == .postgresql ? 5432 : 3306 }
    var suggestedLocalPort: Int { self == .postgresql ? 15432 : 13306 }
}

nonisolated enum CredentialKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case databasePassword
    case awsIAM
    var id: String { rawValue }
    var title: String { self == .awsIAM ? "AWS IAM" : "Database password" }
}

nonisolated struct CredentialReference: Codable, Equatable, Sendable {
    let kind: CredentialKind
    let id: UUID
}

/// Editable, non-secret values. Views edit a draft rather than a live SwiftData record.
nonisolated struct ConnectionDraft: Equatable, Sendable {
    var name: String
    var engine: DatabaseEngine
    var host: String
    var upstreamPort: Int
    var localPort: Int
    var database: String = ""
    var credential: CredentialReference
    var iamDatabaseUsername: String = ""
    var awsRegion: String = ""

    func validated() throws -> Self {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        result.awsRegion = awsRegion.trimmingCharacters(in: .whitespacesAndNewlines)

        try Self.validateEndpoint(name: result.name, host: result.host, upstreamPort: upstreamPort, localPort: localPort)

        if credential.kind == .awsIAM {
            guard !iamDatabaseUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigurationError.required("IAM database username")
            }
            guard !result.awsRegion.isEmpty else { throw ConfigurationError.required("Database AWS region") }
        } else {
            // Do not retain stale IAM settings when switching to a password credential.
            result.iamDatabaseUsername = ""
            result.awsRegion = ""
        }
        return result
    }

    static func validateEndpoint(name: String, host: String, upstreamPort: Int, localPort: Int) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConfigurationError.required("Connection name") }
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw ConfigurationError.required("Upstream host") }
        guard !host.contains(where: { $0.isWhitespace || "/@?#".contains($0) }) else { throw ConfigurationError.invalidHost }
        guard (1...65535).contains(upstreamPort) else { throw ConfigurationError.invalidPort("Upstream port") }
        guard (1...65535).contains(localPort) else { throw ConfigurationError.invalidPort("Local port") }
    }
}

nonisolated enum ConfigurationError: Error, Equatable, LocalizedError {
    case required(String)
    case invalidPort(String)
    case invalidHost
    case invalidAccountID
    case invalidDatabaseRegion
    case iamRequiresTLS
    case missingCredential
    case missingSession
    case missingConnection
    case unsupportedConfiguration
    case connectionActive
    case credentialInUse
    case sessionInUse
    case localPortInUse(Int)
    case configurationChanged

    var errorDescription: String? {
        switch self {
        case .required(let field): "\(field) is required."
        case .invalidPort(let field): "\(field) must be between 1 and 65535."
        case .invalidHost: "Enter a hostname or IP address, without a URL scheme, path, or username."
        case .invalidAccountID: "An AWS account ID must contain exactly 12 digits."
        case .invalidDatabaseRegion: "Enter the AWS region hosting the database, such as eu-west-2."
        case .iamRequiresTLS: "AWS IAM authentication requires verified TLS."
        case .missingCredential: "Choose an existing credential before saving this connection."
        case .missingSession: "Choose an existing Identity Center session."
        case .missingConnection: "This connection no longer exists. Reload the connection list."
        case .unsupportedConfiguration: "This connection contains settings that this version of Quorra cannot use."
        case .connectionActive: "Stop this local endpoint before editing or deleting its configuration."
        case .credentialInUse: "This credential is used by a connection. Reassign or remove that connection first."
        case .sessionInUse: "This session is used by an AWS access profile. Remove its profiles first."
        case .localPortInUse(let port): "Local port \(port) is already assigned to another connection."
        case .configurationChanged: "This connection’s profile changed while it was starting. Start it again."
        }
    }
}
