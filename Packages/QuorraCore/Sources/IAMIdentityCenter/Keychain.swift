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
/// All queries set `kSecUseDataProtectionKeychain: true` to opt into the data-protection keychain
/// on macOS. Without this flag, macOS routes items to the legacy login keychain whose per-item ACL
/// model triggers user-facing approval prompts; the data-protection keychain gates access entirely
/// on the app's `keychain-access-groups` entitlement, so same-team-ID reads/writes are silent.
/// Per Apple's `kSecUseDataProtectionKeychain` reference: *"highly recommended… for all keychain
/// operations."* Items stored with this flag don't appear in `Keychain Access.app`.
///
/// The access group is passed at initialization — production code uses `$(AppIdentifierPrefix)dev.ajbeck.quorra.shared`.
/// Tests do **not** construct this type directly; per Apple's testing guidance (*"Adding tests
/// to your Xcode project"*) they inject a stub conforming to `KeychainStore` instead, because
/// SwiftPM test bundles can't carry the keychain-access-groups entitlement that this concrete
/// implementation requires.
public actor Keychain: KeychainStore {
    /// Keychain access group (e.g. `TEAMID.dev.ajbeck.quorra.shared`).
    public let accessGroup: String

    public init(accessGroup: String) {
        self.accessGroup = accessGroup
    }

    /// Builds the shared attribute set used to identify a single item across all operations.
    /// Always includes `kSecUseDataProtectionKeychain` to keep items in the data-protection
    /// keychain on macOS rather than the legacy login keychain.
    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    // MARK: - Low-level row operations

    /// Read a single Keychain item.
    ///
    /// - Parameters:
    ///   - service: The `kSecAttrService` value.
    ///   - account: The `kSecAttrAccount` value.
    /// - Throws: `.keychainItemMissing` if the item is not found, `.keychainStatus` for other OS errors.
    public func read(service: String, account: String) throws -> Data {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

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
        let query = baseQuery(service: service, account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]

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
        let query = baseQuery(service: service, account: account)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IAMIdentityCenterError.keychainStatus(status)
        }
    }

    /// Returns all `kSecAttrAccount` strings stored under `service`.
    ///
    /// Uses `SecItemCopyMatching` with `kSecMatchLimitAll` and `kSecReturnAttributes: true`.
    ///
    /// Apple's `SecItemCopyMatching` reference notes that combining `kSecReturnData` and
    /// `kSecMatchLimitAll` is not supported for password items (each copy may require
    /// authentication). We therefore request attributes only and ignore the data — the
    /// caller only needs the account strings for enumeration and cascade deletion.
    ///
    /// Returns an empty array when no rows exist for `service` (`errSecItemNotFound`).
    ///
    /// - Throws: `.keychainStatus` on unexpected OS-level failures.
    public func enumerateAccounts(service: String) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw IAMIdentityCenterError.keychainStatus(status)
        }

        guard let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    // Record verbs (`readRecord`/`writeRecord`/`deleteRecord`) are provided by the
    // `KeychainStore` protocol extension in `KeychainStore.swift`.
}
