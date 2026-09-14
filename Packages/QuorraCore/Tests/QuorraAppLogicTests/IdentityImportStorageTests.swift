import Foundation
import QuorraAppLogic
import Testing

struct IdentityImportStorageTests {
    let defaults: UserDefaults
    let storage: IdentityImportStorage
    let suiteName: String

    init() {
        let name = "dev.ajbeck.quorra.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        suiteName = name
        self.defaults = defaults
        storage = IdentityImportStorage(defaults: defaults)
    }

    @Test func importIsNotCompletedUntilMarked() {
        #expect(storage.hasCompleted == false)
        storage.markCompleted()
        #expect(storage.hasCompleted == true)
        storage.clear()
        #expect(storage.hasCompleted == false)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
