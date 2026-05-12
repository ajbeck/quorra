import Foundation
import Security

/// Actor-isolated Keychain wrapper for the shared access group.
///
/// Provides low-level row operations (`read`, `write`, `delete`) and high-level record operations
/// (`readRecord`, `writeRecord`, `deleteRecord`) that store an `Encodable` value as a single
/// atomic Keychain row. A missing row throws `.keychainItemMissing`; a corrupt payload throws
/// `.keychainMalformed`. Atomicity-per-record means partial-write recovery is automatic — there's
/// no intermediate state where some fields are persisted and others aren't.
///
/// The access group is passed at initialization — production code uses `$(AppIdentifierPrefix)dev.ajbeck.quorra.shared`;
/// tests inject a per-test UUID to ensure hermeticity.
public actor Keychain {
    /// Keychain access group (e.g. `TEAMID.dev.ajbeck.quorra.shared`).
    public let accessGroup: String

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(accessGroup: String) {
        self.accessGroup = accessGroup
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .secondsSince1970
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .secondsSince1970
    }

    // MARK: - Low-level row operations

    /// Read a single Keychain item.
    ///
    /// - Parameters:
    ///   - service: The `kSecAttrService` value.
    ///   - account: The `kSecAttrAccount` value.
    /// - Throws: `.keychainItemMissing` if the item is not found, `.keychainStatus` for other OS errors.
    public func read(service: String, account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            throw IAMIdentityCenterError.keychainItemMissing(service: service, account: account)
        }
        guard status == errSecSuccess else {
            throw IAMIdentityCenterError.keychainStatus(status)
        }
        guard let data = result as? Data else {
            throw IAMIdentityCenterError.keychainMalformed(reason: "Item exists but is not Data")
        }
        return data
    }

    /// Write a single Keychain item (update if exists, add if missing).
    ///
    /// - Parameters:
    ///   - data: The secret data to store.
    ///   - service: The `kSecAttrService` value.
    ///   - account: The `kSecAttrAccount` value.
    /// - Throws: `.keychainStatus` on OS-level failure.
    public func write(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            // kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly: usable after first unlock since boot;
            // ThisDeviceOnly suffix prevents Migration Assistant from copying secrets to a new Mac.
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            throw IAMIdentityCenterError.keychainStatus(status)
        }
    }

    /// Delete a single Keychain item.
    ///
    /// - Parameters:
    ///   - service: The `kSecAttrService` value.
    ///   - account: The `kSecAttrAccount` value.
    /// - Throws: `.keychainStatus` on OS-level failure (not-found is not an error).
    public func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IAMIdentityCenterError.keychainStatus(status)
        }
    }

    // MARK: - High-level record operations

    /// Read a record stored as a JSON-encoded row and decode it to `T`.
    ///
    /// - Throws: `.keychainItemMissing` if no row exists for `(service, account)`;
    ///           `.keychainMalformed` if the row exists but won't decode.
    public func readRecord<T: Decodable>(_ type: T.Type, service: String, account: String) throws -> T {
        let data = try read(service: service, account: account)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw IAMIdentityCenterError.keychainMalformed(reason: String(reflecting: error))
        }
    }

    /// Encode `value` as JSON and write it as a single Keychain row.
    public func writeRecord<T: Encodable>(_ value: T, service: String, account: String) throws {
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw IAMIdentityCenterError.keychainMalformed(reason: String(reflecting: error))
        }
        try write(data, service: service, account: account)
    }

    /// Delete the record at `(service, account)`. Missing rows are not an error.
    public func deleteRecord(service: String, account: String) throws {
        try delete(service: service, account: account)
    }
}
