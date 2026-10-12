import DatabaseProxy
import Foundation
import SwiftData

/// A local database endpoint: Quorra listens on `127.0.0.1:localPort` and relays to the upstream
/// database, signing in with the profile's IAM role or a saved database credential.
@Model
public final class DatabaseConnectionDefinition {
    public var stableIDString: String
    public var name: String
    public var engineRawValue: String
    public var host: String
    public var upstreamPort: Int
    public var localPort: Int
    public var database: String
    /// The database user IAM tokens are signed for. Password logins use the credential's username.
    public var username: String
    /// The region hosting the database, used to sign IAM tokens.
    public var region: String
    public var authenticationRawValue: String
    public var localAuthenticationRawValue: String
    public var tlsModeRawValue: String
    public var trustRawValue: String
    public var isFavorite: Bool
    public var profile: ProfileDefinition?
    public var credential: DatabaseCredentialDefinition?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), draft: DatabaseConnectionDraft, profile: ProfileDefinition?, credential: DatabaseCredentialDefinition?) {
        stableIDString = id.uuidString
        name = ""
        engineRawValue = ""
        host = ""
        upstreamPort = 0
        localPort = 0
        database = ""
        username = ""
        region = ""
        authenticationRawValue = ""
        localAuthenticationRawValue = ""
        tlsModeRawValue = ""
        trustRawValue = ""
        isFavorite = false
        createdAt = .now
        updatedAt = .now
        apply(draft, profile: profile, credential: credential)
    }

    public var stableID: UUID {
        UUID(uuidString: stableIDString) ?? UUID()
    }

    public var engine: DatabaseEngine { DatabaseEngine(rawValue: engineRawValue) ?? .postgresql }
    public var authentication: CredentialKind { CredentialKind(rawValue: authenticationRawValue) ?? .awsIAM }

    /// Copies a draft's settings. IAM connections keep no credential and password connections no profile.
    public func apply(_ draft: DatabaseConnectionDraft, profile: ProfileDefinition?, credential: DatabaseCredentialDefinition?) {
        name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        engineRawValue = draft.engine.rawValue
        host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        upstreamPort = draft.upstreamPort
        localPort = draft.localPort
        database = draft.database
        username = draft.authentication == .awsIAM ? draft.username : ""
        region = draft.authentication == .awsIAM ? draft.region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : ""
        authenticationRawValue = draft.authentication.rawValue
        localAuthenticationRawValue = draft.localAuthentication.rawValue
        tlsModeRawValue = draft.tlsMode.rawValue
        trustRawValue = draft.trust.rawValue
        self.profile = draft.authentication == .awsIAM ? profile : nil
        self.credential = draft.authentication == .databasePassword ? credential : nil
        updatedAt = .now
    }

    /// The editable draft, with the profile's coordinates and the credential's login username.
    /// Unknown stored values fall back to the safest setting: verified TLS and a generated password.
    public var draft: DatabaseConnectionDraft {
        let coordinates = profile?.credentialCoordinates
        return DatabaseConnectionDraft(
            name: name, host: host, upstreamPort: upstreamPort, localPort: localPort, database: database,
            username: authentication == .awsIAM ? username : credential?.username ?? "", region: region,
            sessionName: coordinates?.session, accountID: profile?.accountID ?? "", roleName: profile?.roleName ?? "",
            trust: DatabaseTLSOptions.TrustSource(rawValue: trustRawValue) ?? .rds,
            localAuthentication: LocalAuthentication(rawValue: localAuthenticationRawValue) ?? .generatedPassword,
            authentication: authentication, passwordCredentialID: credential?.stableID,
            tlsMode: UpstreamTLSMode(rawValue: tlsModeRawValue) ?? .verified, engine: engine
        )
    }
}

/// A saved database username and password, shared by any number of password connections.
/// The password lives only in the Keychain, keyed by this record's stable ID.
@Model
public final class DatabaseCredentialDefinition {
    public var stableIDString: String
    public var name: String
    public var username: String
    public var createdAt: Date
    public var updatedAt: Date

    @Relationship(deleteRule: .nullify, inverse: \DatabaseConnectionDefinition.credential)
    public var connections: [DatabaseConnectionDefinition]

    public init(id: UUID = UUID(), name: String, username: String, createdAt: Date = .now, updatedAt: Date = .now) {
        stableIDString = id.uuidString
        self.name = name
        self.username = username
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        connections = []
    }

    public var stableID: UUID {
        UUID(uuidString: stableIDString) ?? UUID()
    }
}
