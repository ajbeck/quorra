import Foundation
import IAMIdentityCenter
import SwiftData

/// Saved VPN profiles' `.ovpn` text in the Keychain, by profile ID.
public struct ClientVPNProfileSecrets: Sendable {
    public static let service = "dev.ajbeck.quorra.client-vpn-profile"

    private let keychain: any KeychainStore

    public init(keychain: any KeychainStore) {
        self.keychain = keychain
    }

    func setProfile(_ profile: ClientVPNProfile, for id: UUID) async throws {
        try await keychain.write(Data(profile.text.utf8), service: Self.service, account: id.uuidString)
    }

    func profile(for id: UUID) async throws -> ClientVPNProfile {
        let data: Data
        do { data = try await keychain.read(service: Self.service, account: id.uuidString) }
        catch IAMIdentityCenterError.keychainItemMissing { throw ClientVPNProfileError.missingFromKeychain }
        return try ClientVPNProfile(data: data)
    }

    func deleteProfile(for id: UUID) async throws {
        try await keychain.delete(service: Self.service, account: id.uuidString)
    }
}

/// Adds, edits and deletes saved VPN profiles. Connecting belongs to `ClientVPNController`; callers
/// disconnect a profile before deleting it, and forget its session token when its endpoint or file changes.
@MainActor
public enum ClientVPNProfileStore {
    public static func profiles(in context: ModelContext) throws -> [ClientVPNProfileDefinition] {
        try context.fetch(FetchDescriptor<ClientVPNProfileDefinition>())
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func profile(id: UUID, in context: ModelContext) throws -> ClientVPNProfileDefinition? {
        let idString = id.uuidString
        var descriptor = FetchDescriptor<ClientVPNProfileDefinition>(predicate: #Predicate { $0.stableIDString == idString })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Saves an imported profile under `name`, connecting to `endpoint`.
    @discardableResult
    public static func add(
        _ profile: ClientVPNProfile,
        fileName: String,
        name: String,
        endpoint: String,
        secrets: ClientVPNProfileSecrets,
        in context: ModelContext
    ) async throws -> ClientVPNProfileDefinition {
        let definition = ClientVPNProfileDefinition(name: try checkedName(name), endpoint: try ClientVPNProfile.endpoint(from: endpoint), profile: profile, fileName: fileName)
        // Write the secret first so a saved record always has its profile.
        try await secrets.setProfile(profile, for: definition.stableID)
        context.insert(definition)
        try context.save()
        return definition
    }

    public static func save(_ definition: ClientVPNProfileDefinition, name: String, endpoint: String, in context: ModelContext) throws {
        let name = try checkedName(name)
        let endpoint = try ClientVPNProfile.endpoint(from: endpoint)
        definition.name = name
        definition.endpoint = endpoint
        definition.updatedAt = .now
        try context.save()
    }

    /// Replaces the `.ovpn` file. An endpoint that followed the old file follows the new one; one
    /// the user chose stays.
    public static func replaceProfile(
        of definition: ClientVPNProfileDefinition,
        with profile: ClientVPNProfile,
        fileName: String,
        secrets: ClientVPNProfileSecrets,
        in context: ModelContext
    ) async throws {
        try await secrets.setProfile(profile, for: definition.stableID)
        if definition.endpoint == definition.profileEndpoint { definition.endpoint = profile.endpoint }
        definition.apply(profile, fileName: fileName)
        try context.save()
    }

    /// Deletes a profile and its Keychain item. A profile a database still uses is kept, and the
    /// error names those databases.
    public static func delete(_ definition: ClientVPNProfileDefinition, secrets: ClientVPNProfileSecrets, in context: ModelContext) async throws {
        guard definition.connections.isEmpty else {
            throw ClientVPNProfileError.inUse(definition.connections.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        }
        let id = definition.stableID
        context.delete(definition)
        try context.save()
        try await secrets.deleteProfile(for: id)
    }

    /// The text to connect with: the saved profile with the chosen endpoint.
    public static func connectionText(for definition: ClientVPNProfileDefinition, secrets: ClientVPNProfileSecrets) async throws -> String {
        let endpoint = definition.endpoint
        return try await secrets.profile(for: definition.stableID).text(endpoint: endpoint)
    }

    private static func checkedName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ClientVPNProfileError.missingName }
        return name
    }
}
