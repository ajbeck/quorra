import Foundation

/// Versioned, non-secret interchange format, shared with Duck Blind's version 1 files. Local
/// UUIDs and Keychain values deliberately have no representation in this document.
public nonisolated struct ConnectionImport: Decodable, Sendable {
    public static let maximumBytes = 65_536
    public let version: Int
    public let name: String
    public let engine: DatabaseEngine
    public let host: String
    public let database: String
    public let authentication: CredentialKind
    public let upstreamPort: Int?
    public let localPort: Int?
    public let username: String?
    public let region: String?
    public let accountID: String?
    public let roleName: String?
    public let sessionName: String?
    public let credentialName: String?
    public let tlsMode: UpstreamTLSMode?
    public let trust: DatabaseTLSOptions.TrustSource?
    public let localAuthentication: LocalAuthentication?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, name, engine, host, database, authentication, upstreamPort, localPort
        case username, region, accountID, roleName, sessionName, credentialName, tlsMode, trust, localAuthentication
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw ConnectionImportError.tooLarge }
        do {
            guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ConnectionImportError.invalidDocument
            }
            guard Set(fields.keys).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else {
                throw ConnectionImportError.unsupportedFields
            }
            // Optional means omitted; null usually signals a malformed template.
            guard !fields.values.contains(where: { $0 is NSNull }) else { throw ConnectionImportError.invalidDocument }
            let document = try JSONDecoder().decode(Self.self, from: data)
            guard document.version == 1 else { throw ConnectionImportError.unsupportedVersion }
            let strings = [document.name, document.host, document.database, document.username, document.region,
                           document.accountID, document.roleName, document.sessionName, document.credentialName].compactMap { $0 }
            guard strings.allSatisfy({ $0.count <= 1024 && !$0.contains("\0") }) else { throw ConnectionImportError.invalidDocument }
            if document.authentication == .awsIAM {
                guard document.credentialName == nil else { throw ConnectionImportError.conflictingAuthentication }
            } else {
                guard [document.username, document.region, document.accountID, document.roleName, document.sessionName].allSatisfy({ $0 == nil }) else {
                    throw ConnectionImportError.conflictingAuthentication
                }
            }
            try document.draft().validateSettings()
            return document
        } catch let error as ConnectionImportError { throw error }
        catch let error as ConfigurationError { throw error }
        catch { throw ConnectionImportError.invalidDocument }
    }

    public static func load(from url: URL) async throws -> Self {
        let read = Task.detached(priority: .userInitiated) { () throws -> Self in
            try Task.checkCancellation()
            guard url.isFileURL else { throw ConnectionImportError.unreadable }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else { throw ConnectionImportError.unreadable }
                guard (values.fileSize ?? 0) <= maximumBytes else { throw ConnectionImportError.tooLarge }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
                try Task.checkCancellation()
                return try decode(data)
            } catch let error as ConnectionImportError { throw error }
            catch let error as ConfigurationError { throw error }
            catch is CancellationError { throw CancellationError() }
            catch { throw ConnectionImportError.unreadable }
        }
        return try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
    }

    /// The editable draft. The file names the profile by session, account and role, and the
    /// password credential by name; callers match those against saved records.
    public func draft(usedLocalPorts: Set<Int> = []) throws -> DatabaseConnectionDraft {
        let port: Int
        if let localPort { port = localPort }
        else {
            let suggested = engine.suggestedLocalPort
            guard let available = (suggested...65535).first(where: { !usedLocalPorts.contains($0) })
                    ?? (1024..<suggested).first(where: { !usedLocalPorts.contains($0) }) else {
                throw ConnectionImportError.noAvailablePort
            }
            port = available
        }
        return .init(name: name, host: host, upstreamPort: upstreamPort ?? engine.defaultPort, localPort: port,
                     database: database, username: username ?? "", region: region ?? "",
                     sessionName: authentication == .awsIAM ? sessionName : nil,
                     accountID: accountID ?? "", roleName: roleName ?? "",
                     trust: trust ?? (authentication == .awsIAM ? .rds : .system),
                     localAuthentication: localAuthentication ?? .generatedPassword, authentication: authentication,
                     tlsMode: tlsMode ?? .verified, engine: engine)
    }

    public var credentialHint: String {
        if authentication == .awsIAM {
            return sessionName.map { "Requested profile: \($0), account \(accountID ?? "?"), role \(roleName ?? "?"). Confirm the selected profile below." }
                ?? "Choose a profile below."
        }
        return credentialName.map { "Requested database credential: \($0). Confirm the selected credential below." }
            ?? "Choose a saved database credential below."
    }
}

public nonisolated enum ConnectionImportError: Error, LocalizedError, Equatable {
    case invalidDocument, unsupportedVersion, unsupportedFields, conflictingAuthentication, tooLarge, unreadable, noAvailablePort
    public var errorDescription: String? {
        switch self {
        case .invalidDocument: "Use a valid Quorra or Duck Blind connection file with version, name, engine, host, database and authentication fields. Check the field types and supported values in the import guide."
        case .unsupportedVersion: "This version of Quorra imports connection file version 1."
        case .unsupportedFields: "The file contains unsupported fields. Import connection settings only; passwords, tokens and local credential IDs are not supported. See the import guide for accepted fields."
        case .conflictingAuthentication: "The authentication fields do not match the selected method. Use AWS identity fields with awsIAM, or credentialName with databasePassword."
        case .tooLarge: "Choose a single-connection JSON file no larger than 64 KiB."
        case .unreadable: "The configuration file could not be read. Choose an accessible JSON file and try again."
        case .noAvailablePort: "No unused local port could be suggested. Include an explicit localPort in the file."
        }
    }
    public static func message(_ error: any Error) -> String {
        if error is ConnectionImportError || error is ConfigurationError { return error.localizedDescription }
        return ConnectionImportError.unreadable.localizedDescription
    }
}
