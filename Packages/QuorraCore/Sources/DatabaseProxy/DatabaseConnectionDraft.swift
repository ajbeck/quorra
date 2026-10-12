import Foundation

nonisolated enum LocalAuthentication: String, Codable, CaseIterable, Identifiable, Sendable {
    case generatedPassword
    case trustLoopback
    var id: String { rawValue }
    var title: String { self == .generatedPassword ? "Generated password" : "Trust localhost" }
}

nonisolated enum UpstreamTLSMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case verified, disabled
    var id: String { rawValue }
    var title: String { self == .verified ? "Verified TLS" : "Off" }
}

nonisolated struct DatabaseConnectionDraft: Equatable, Sendable {
    static let localUsername = "quorra"

    var localAddress: String { "127.0.0.1:\(localPort)" }
    var upstreamAddress: String { "\(host):\(upstreamPort)" }
    var localURL: String? {
        var url = URLComponents()
        url.scheme = engine == .postgresql ? "postgresql" : "mysql"
        url.host = "127.0.0.1"
        url.port = localPort
        url.user = Self.localUsername
        url.percentEncodedPath = "/" + (database.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? "")
        if engine == .postgresql { url.queryItems = [.init(name: "sslmode", value: "disable")] }
        return url.string
    }

    var name = ""
    var host = ""
    var upstreamPort = 5432
    var localPort = 15432
    var database = ""
    var username = ""
    var region = ""
    var sessionName: String?
    var accountID = ""
    var roleName = ""
    var trust = DatabaseTLSOptions.TrustSource.rds
    var localAuthentication = LocalAuthentication.generatedPassword
    var authentication = CredentialKind.awsIAM
    var passwordCredentialID: UUID?
    var tlsMode = UpstreamTLSMode.verified
    var engine = DatabaseEngine.postgresql

    func connection(credentialID: UUID) throws -> ConnectionDraft {
        try validateSettings()
        if authentication == .awsIAM {
            guard sessionName != nil else { throw ConfigurationError.missingSession }
        } else {
            guard passwordCredentialID == credentialID else { throw ConfigurationError.missingCredential }
        }
        return try ConnectionDraft(name: name, engine: engine, host: host,
                                   upstreamPort: upstreamPort, localPort: localPort, database: database,
                                   credential: .init(kind: authentication, id: credentialID),
                                   iamDatabaseUsername: username,
                                   awsRegion: region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).validated()
    }

    /// Validate portable settings before an imported draft has local credentials.
    func validateSettings() throws {
        try ConnectionDraft.validateEndpoint(name: name, host: host, upstreamPort: upstreamPort, localPort: localPort)
        guard !database.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConfigurationError.required("Database") }
        guard ![name, host, database, username, region, roleName].contains(where: { $0.contains("\0") }) else {
            throw ConfigurationError.invalidHost
        }
        let region = region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if authentication == .awsIAM {
            guard tlsMode == .verified else { throw ConfigurationError.iamRequiresTLS }
            guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConfigurationError.required("IAM database username") }
            guard accountID.utf8.count == 12, accountID.utf8.allSatisfy({ (48...57).contains($0) }) else {
                throw ConfigurationError.invalidAccountID
            }
            guard !roleName.isEmpty else { throw ConfigurationError.required("AWS role") }
            guard region.range(of: "^[a-z]{2}(-[a-z]+)+-[0-9]+$", options: .regularExpression) != nil else {
                throw ConfigurationError.invalidDatabaseRegion
            }
        }
    }
}

nonisolated struct DatabaseConnectionSummary: Identifiable, Sendable {
    let id: UUID
    let draft: DatabaseConnectionDraft
    let credentialID: UUID
    let sessionName: String

    func validate(binding: DatabaseRoleBinding?) throws {
        _ = try draft.connection(credentialID: credentialID)
        if draft.authentication == .awsIAM {
            guard let binding, draft.sessionName == binding.sessionName,
                  draft.accountID == binding.accountID, draft.roleName == binding.roleName else {
                throw ConfigurationError.configurationChanged
            }
        } else if binding != nil {
            throw ConfigurationError.unsupportedConfiguration
        }
    }
}
