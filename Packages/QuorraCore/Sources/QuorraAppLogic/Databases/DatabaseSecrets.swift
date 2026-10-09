import DatabaseProxy
import Foundation
import IAMIdentityCenter
import Security

/// Database passwords in the Keychain: saved credentials by credential ID, and each connection's
/// generated local password by connection ID.
public struct DatabaseSecrets: Sendable {
    public static let passwordService = "dev.ajbeck.quorra.database-password"
    public static let localPasswordService = "dev.ajbeck.quorra.database-local-password"

    private let keychain: any KeychainStore

    public init(keychain: any KeychainStore) {
        self.keychain = keychain
    }

    public func setPassword(_ password: String, forCredential id: UUID) async throws {
        guard !password.isEmpty else { throw ConfigurationError.required("Password") }
        guard !password.contains("\0") else { throw ConfigurationError.required("A password without null characters") }
        try await keychain.write(Data(password.utf8), service: Self.passwordService, account: id.uuidString)
    }

    public func password(forCredential id: UUID) async throws -> String {
        let data: Data
        do { data = try await keychain.read(service: Self.passwordService, account: id.uuidString) }
        catch IAMIdentityCenterError.keychainItemMissing { throw ConfigurationError.missingCredential }
        guard let password = String(data: data, encoding: .utf8), !password.isEmpty, !password.contains("\0") else {
            throw ConfigurationError.missingCredential
        }
        return password
    }

    public func deletePassword(forCredential id: UUID) async throws {
        try await keychain.delete(service: Self.passwordService, account: id.uuidString)
    }

    /// The password local clients use for a generated-password connection. It stays the same
    /// across edits, and switching to trust-localhost keeps it for a later switch back.
    public func localPassword(forConnection id: UUID) async throws -> String {
        do {
            let data = try await keychain.read(service: Self.localPasswordService, account: id.uuidString)
            if let password = String(data: data, encoding: .utf8), !password.isEmpty { return password }
        } catch IAMIdentityCenterError.keychainItemMissing {}
        var random = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
        guard status == errSecSuccess else { throw IAMIdentityCenterError.keychainStatus(status) }
        let password = Data(random).base64EncodedString()
        try await keychain.write(Data(password.utf8), service: Self.localPasswordService, account: id.uuidString)
        return password
    }

    public func deleteLocalPassword(forConnection id: UUID) async throws {
        try await keychain.delete(service: Self.localPasswordService, account: id.uuidString)
    }
}
