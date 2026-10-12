import DatabaseProxy
import Foundation
import SwiftData

/// Saves, deletes and resolves database connections and credentials. Starting and stopping
/// connections belongs to the runtime; callers stop a connection before editing or deleting it.
@MainActor
public enum DatabaseStore {
    public static func connections(in context: ModelContext) throws -> [DatabaseConnectionDefinition] {
        try context.fetch(FetchDescriptor<DatabaseConnectionDefinition>())
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func connection(id: UUID, in context: ModelContext) throws -> DatabaseConnectionDefinition? {
        let idString = id.uuidString
        var descriptor = FetchDescriptor<DatabaseConnectionDefinition>(predicate: #Predicate { $0.stableIDString == idString })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    public static func credentials(in context: ModelContext) throws -> [DatabaseCredentialDefinition] {
        try context.fetch(FetchDescriptor<DatabaseCredentialDefinition>())
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Validates and saves a connection. IAM connections need a profile with a session; password
    /// connections need a saved credential. Local ports are unique across connections.
    @discardableResult
    public static func saveConnection(
        _ existing: DatabaseConnectionDefinition?,
        draft: DatabaseConnectionDraft,
        profile: ProfileDefinition?,
        credential: DatabaseCredentialDefinition?,
        in context: ModelContext
    ) throws -> DatabaseConnectionDefinition {
        var checked = draft
        if draft.authentication == .awsIAM {
            guard let profile, let coordinates = profile.credentialCoordinates else { throw ConfigurationError.missingSession }
            checked.sessionName = coordinates.session
            checked.accountID = profile.accountID
            checked.roleName = profile.roleName
        } else {
            guard credential != nil else { throw ConfigurationError.missingCredential }
        }
        try checked.validateSettings()
        let others = try connections(in: context).filter { $0 !== existing }
        guard !others.contains(where: { $0.localPort == draft.localPort }) else {
            throw ConfigurationError.localPortInUse(draft.localPort)
        }
        if let existing {
            existing.apply(checked, profile: profile, credential: credential)
            try context.save()
            return existing
        }
        let connection = DatabaseConnectionDefinition(draft: checked, profile: profile, credential: credential)
        context.insert(connection)
        try context.save()
        return connection
    }

    /// Deletes a connection and its generated local password.
    public static func deleteConnection(_ connection: DatabaseConnectionDefinition, secrets: DatabaseSecrets, in context: ModelContext) async throws {
        let id = connection.stableID
        context.delete(connection)
        try context.save()
        try await secrets.deleteLocalPassword(forConnection: id)
    }

    /// Saves a credential's name and username, and its password when one is given. A new
    /// credential needs a password.
    @discardableResult
    public static func saveCredential(
        _ existing: DatabaseCredentialDefinition?,
        name: String,
        username: String,
        password: String?,
        secrets: DatabaseSecrets,
        in context: ModelContext
    ) async throws -> DatabaseCredentialDefinition {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ConfigurationError.required("Credential name") }
        // Quoted database usernames can contain significant spaces and case.
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConfigurationError.required("Database username") }
        guard !username.contains("\0") else { throw ConfigurationError.required("A database username without null characters") }
        if existing == nil, password == nil { throw ConfigurationError.required("Password") }

        let credential = existing ?? DatabaseCredentialDefinition(name: name, username: username)
        // Write the secret first so a saved record always has a password.
        if let password { try await secrets.setPassword(password, forCredential: credential.stableID) }
        credential.name = name
        credential.username = username
        credential.updatedAt = .now
        if existing == nil { context.insert(credential) }
        try context.save()
        return credential
    }

    /// Deletes a credential and its password. A credential still used by a connection is kept,
    /// and the error names those connections.
    public static func deleteCredential(_ credential: DatabaseCredentialDefinition, secrets: DatabaseSecrets, in context: ModelContext) async throws {
        guard credential.connections.isEmpty else {
            throw ConfigurationError.credentialInUse(credential.connections.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        }
        let id = credential.stableID
        context.delete(credential)
        try context.save()
        try await secrets.deletePassword(forCredential: id)
    }

    /// The upstream login for a password connection. The username and password are read one
    /// after the other, so an edit landing in between is caught only by the database rejecting it.
    public static func login(for connection: DatabaseConnectionDefinition, secrets: DatabaseSecrets) async throws -> DatabaseLogin {
        guard let credential = connection.credential else { throw ConfigurationError.missingCredential }
        let username = credential.username
        return DatabaseLogin(username: username, password: try await secrets.password(forCredential: credential.stableID))
    }

    /// The proxy's view of a connection. IAM connections are keyed by their profile and
    /// password connections by their credential.
    public static func summary(for connection: DatabaseConnectionDefinition) -> DatabaseConnectionSummary {
        let credentialID = connection.authentication == .awsIAM
            ? connection.profile?.stableID ?? connection.stableID
            : connection.credential?.stableID ?? connection.stableID
        return DatabaseConnectionSummary(
            id: connection.stableID,
            draft: connection.draft,
            credentialID: credentialID,
            sessionName: connection.profile?.session?.name ?? ""
        )
    }

    /// The draft for an imported file, matched to the one profile with the file's session,
    /// account and role, or the one credential with the file's credential name. No match or
    /// several leave the choice to the editor.
    public static func importDraft(
        _ file: ConnectionImport,
        in context: ModelContext
    ) throws -> (draft: DatabaseConnectionDraft, profile: ProfileDefinition?, credential: DatabaseCredentialDefinition?) {
        let usedPorts = Set(try connections(in: context).map(\.localPort))
        let draft = try file.draft(usedLocalPorts: usedPorts)
        if file.authentication == .awsIAM {
            let matches = try IdentityStore.profiles(in: context).filter {
                $0.session?.name == file.sessionName && $0.accountID == file.accountID && $0.roleName == file.roleName
            }
            return (draft, matches.count == 1 ? matches[0] : nil, nil)
        }
        let matches = try credentials(in: context).filter { $0.name == file.credentialName }
        return (draft, nil, matches.count == 1 ? matches[0] : nil)
    }
}
