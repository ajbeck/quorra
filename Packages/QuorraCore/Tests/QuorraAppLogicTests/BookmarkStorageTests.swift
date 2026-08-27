import Foundation
import QuorraAppLogic
import Testing

struct BookmarkStorageTests {
    let defaults: UserDefaults
    let storage: BookmarkStorage
    let suiteName: String

    init() {
        let name = "dev.ajbeck.quorra.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        suiteName = name
        self.defaults = defaults
        storage = BookmarkStorage(defaults: defaults)
    }

    @Test func loadReturnsNilWhenEmpty() {
        #expect(storage.load() == nil)
    }

    @Test func saveAndLoadRoundTrip() {
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        storage.save(payload)
        #expect(storage.load() == payload)
        tearDown()
    }

    @Test func clearRemovesStoredData() {
        storage.save(Data([0x01]))
        storage.clear()
        #expect(storage.load() == nil)
        tearDown()
    }

    private func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
