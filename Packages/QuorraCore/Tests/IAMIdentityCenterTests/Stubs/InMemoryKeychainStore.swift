import Foundation
import Synchronization
@testable import IAMIdentityCenter

/// In-memory `KeychainStore` for tests. Stores raw bytes keyed by `(service, account)`;
/// reproduces the observable error behavior of the production `Keychain` actor without
/// touching the Security framework. Record verbs come from the `KeychainStore` extension.
///
/// A `Mutex` guards the storage instead of actor isolation so `readSynchronously` can run
/// from any thread, as the production wrapper's does.
final class InMemoryKeychainStore: KeychainStore, Sendable {
    private struct Key: Hashable {
        let service: String
        let account: String
    }

    private let storage = Mutex<[Key: Data]>([:])

    func read(service: String, account: String) async throws -> Data {
        try readSynchronously(service: service, account: account)
    }

    func readSynchronously(service: String, account: String) throws -> Data {
        guard let data = storage.withLock({ $0[Key(service: service, account: account)] }) else {
            throw IAMIdentityCenterError.keychainItemMissing(service: service, account: account)
        }
        return data
    }

    func write(_ data: Data, service: String, account: String) async {
        storage.withLock { $0[Key(service: service, account: account)] = data }
    }

    func delete(service: String, account: String) async {
        storage.withLock { $0[Key(service: service, account: account)] = nil }
    }

    func enumerateAccounts(service: String) async -> [String] {
        storage.withLock { store in
            store.keys
                .filter { $0.service == service }
                .map { $0.account }
        }
    }
}
