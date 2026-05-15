import Foundation
@testable import IAMIdentityCenter

/// In-memory `KeychainStore` for tests. Stores raw bytes keyed by `(service, account)`;
/// reproduces the observable error behavior of the production `Keychain` actor without
/// touching the Security framework. Record verbs come from the `KeychainStore` extension.
actor InMemoryKeychainStore: KeychainStore {
    private struct Key: Hashable {
        let service: String
        let account: String
    }

    private var storage: [Key: Data] = [:]

    func read(service: String, account: String) throws -> Data {
        guard let data = storage[Key(service: service, account: account)] else {
            throw IAMIdentityCenterError.keychainItemMissing(service: service, account: account)
        }
        return data
    }

    func write(_ data: Data, service: String, account: String) {
        storage[Key(service: service, account: account)] = data
    }

    func delete(service: String, account: String) {
        storage[Key(service: service, account: account)] = nil
    }

    func enumerateAccounts(service: String) -> [String] {
        storage.keys
            .filter { $0.service == service }
            .map { $0.account }
    }
}
