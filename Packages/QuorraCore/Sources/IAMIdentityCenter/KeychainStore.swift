import Foundation

/// Protocol surface of the keychain wrapper, for dependency injection.
///
/// Production uses `Keychain` (Security-framework-backed). Tests use an in-memory conformer
/// because SwiftPM test bundles can't carry the `keychain-access-groups` entitlement that the
/// data-protection keychain requires (TN3137).
///
/// Conformers implement only the byte-level verbs (`read`/`write`/`delete`); the JSON-record
/// verbs are provided by the default extension below.
public protocol KeychainStore: Sendable {
    /// Read raw bytes for `(service, account)`. Throws `.keychainItemMissing` when absent.
    func read(service: String, account: String) async throws -> Data

    /// Write raw bytes for `(service, account)`. Overwrites existing.
    func write(_ data: Data, service: String, account: String) async throws

    /// Delete the row at `(service, account)`. Missing rows are not an error.
    func delete(service: String, account: String) async throws

    /// Returns all `kSecAttrAccount` strings stored under `service`.
    ///
    /// Used by the sign-out cascade (D27) to enumerate and purge role-credential rows for a
    /// session. The caller filters the returned strings by prefix to isolate the target session.
    ///
    /// Returns an empty array when no rows exist for `service` (not an error).
    /// The returned order is unspecified — callers must not depend on it.
    func enumerateAccounts(service: String) async throws -> [String]

    /// Decode a JSON-encoded row at `(service, account)` to `T`.
    /// Throws `.keychainItemMissing` if absent, `.keychainMalformed` if the payload won't decode.
    func readRecord<T: Decodable & Sendable>(_ type: T.Type, service: String, account: String) async throws -> T

    /// Encode `value` to JSON and write it as a single row at `(service, account)`.
    func writeRecord<T: Encodable & Sendable>(_ value: T, service: String, account: String) async throws

    /// Delete the record at `(service, account)`. Missing rows are not an error.
    func deleteRecord(service: String, account: String) async throws
}

/// Default record-verb implementations, layered atop the byte-level verbs each conformer provides.
public extension KeychainStore {
    func readRecord<T: Decodable & Sendable>(_ type: T.Type, service: String, account: String) async throws -> T {
        let data = try await read(service: service, account: account)
        do {
            return try KeychainRecordCoder.decoder.decode(T.self, from: data)
        } catch {
            throw IAMIdentityCenterError.keychainMalformed(reason: String(reflecting: error))
        }
    }

    func writeRecord<T: Encodable & Sendable>(_ value: T, service: String, account: String) async throws {
        let data: Data
        do {
            data = try KeychainRecordCoder.encoder.encode(value)
        } catch {
            throw IAMIdentityCenterError.keychainMalformed(reason: String(reflecting: error))
        }
        try await write(data, service: service, account: account)
    }

    func deleteRecord(service: String, account: String) async throws {
        try await delete(service: service, account: account)
    }
}

/// Module-internal JSON coder configured to match Phase A's Codable strategy
/// (`.secondsSince1970` for `Date` fields on stored records).
internal enum KeychainRecordCoder {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}
