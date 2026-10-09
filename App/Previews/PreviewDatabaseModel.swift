#if DEBUG
import Foundation
import IAMIdentityCenter
import QuorraAppLogic
import SwiftData

extension DatabaseModel {
    /// A database model for previews: nothing is saved in the Keychain and no connection can sign in.
    static func preview(container: ModelContainer) -> DatabaseModel {
        DatabaseModel(context: container.mainContext, secrets: DatabaseSecrets(keychain: PreviewKeychain())) { _, _, _, _ in
            throw IAMIdentityCenterError.notSignedIn
        }
    }
}

private struct PreviewKeychain: KeychainStore {
    func read(service: String, account: String) async throws -> Data {
        throw IAMIdentityCenterError.keychainItemMissing(service: service, account: account)
    }

    func readSynchronously(service: String, account: String) throws -> Data {
        throw IAMIdentityCenterError.keychainItemMissing(service: service, account: account)
    }

    func write(_ data: Data, service: String, account: String) async throws {}
    func delete(service: String, account: String) async throws {}
    func enumerateAccounts(service: String) async throws -> [String] { [] }
}
#endif
