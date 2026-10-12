import Foundation

public nonisolated enum LocalAuthentication: String, Codable, CaseIterable, Identifiable, Sendable {
    case generatedPassword
    case trustLoopback
    public var id: String { rawValue }
    public var title: String { self == .generatedPassword ? "Generated password" : "Trust localhost" }
}

public nonisolated enum UpstreamTLSMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case verified, disabled
    public var id: String { rawValue }
    public var title: String { self == .verified ? "Verified TLS" : "Off" }
}

public nonisolated struct DatabaseConnectionDraft: Equatable, Sendable {
    public static let localUsername = "quorra"

    public var localAddress: String { "127.0.0.1:\(localPort)" }
    public var upstreamAddress: String { "\(host):\(upstreamPort)" }
    public var localURL: String? {
        var url = URLComponents()
        url.scheme = engine == .postgresql ? "postgresql" : "mysql"
        url.host = "127.0.0.1"
        url.port = localPort
        url.user = Self.localUsername
        url.percentEncodedPath = "/" + (database.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? "")
        if engine == .postgresql { url.queryItems = [.init(name: "sslmode", value: "disable")] }
        return url.string
    }

    public var name = ""
    public var host = ""
    public var upstreamPort = 5432
    public var localPort = 15432
    public var database = ""
    public var username = ""
    public var region = ""
    public var sessionName: String?
    public var accountID = ""
    public var roleName = ""
    public var trust = DatabaseTLSOptions.TrustSource.rds
    public var localAuthentication = LocalAuthentication.generatedPassword
    public var authentication = CredentialKind.awsIAM
    public var passwordCredentialID: UUID?
    public var tlsMode = UpstreamTLSMode.verified
    public var engine = DatabaseEngine.postgresql

    public init(name: String = "", host: String = "", upstreamPort: Int = 5432, localPort: Int = 15432, database: String = "",
                username: String = "", region: String = "", sessionName: String? = nil, accountID: String = "", roleName: String = "",
                trust: DatabaseTLSOptions.TrustSource = .rds, localAuthentication: LocalAuthentication = .generatedPassword,
                authentication: CredentialKind = .awsIAM, passwordCredentialID: UUID? = nil, tlsMode: UpstreamTLSMode = .verified,
                engine: DatabaseEngine = .postgresql) {
        self.name = name; self.host = host; self.upstreamPort = upstreamPort; self.localPort = localPort; self.database = database
        self.username = username; self.region = region; self.sessionName = sessionName; self.accountID = accountID; self.roleName = roleName
        self.trust = trust; self.localAuthentication = localAuthentication; self.authentication = authentication
        self.passwordCredentialID = passwordCredentialID; self.tlsMode = tlsMode; self.engine = engine
    }

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
    public func validateSettings() throws {
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

public nonisolated struct DatabaseConnectionSummary: Identifiable, Sendable {
    public let id: UUID
    public let draft: DatabaseConnectionDraft
    public let credentialID: UUID
    public let sessionName: String

    public init(id: UUID, draft: DatabaseConnectionDraft, credentialID: UUID, sessionName: String) {
        self.id = id
        self.draft = draft
        self.credentialID = credentialID
        self.sessionName = sessionName
    }

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
