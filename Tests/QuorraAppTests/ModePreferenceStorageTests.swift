import Foundation
import Testing
import AWSConfigINI
@testable import quorra

struct ModePreferenceStorageTests {
    let defaults: UserDefaults
    let storage: ModePreferenceStorage
    let suiteName: String

    init() {
        let name = "dev.ajbeck.quorra.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        self.suiteName = name
        self.defaults = defaults
        self.storage = ModePreferenceStorage(defaults: defaults)
    }

    @Test func loadReturnsManagedWhenNoValuePresent() {
        #expect(storage.load() == .managed)
    }

    @Test func saveAndLoadRoundTripManaged() {
        storage.save(.managed)
        #expect(storage.load() == .managed)
        tearDown()
    }

    @Test func saveAndLoadRoundTripReadOnly() {
        storage.save(.readOnly)
        #expect(storage.load() == .readOnly)
        tearDown()
    }

    @Test func clearRemovesValueAndLoadFallsBack() {
        storage.save(.readOnly)
        storage.clear()
        #expect(storage.load() == .managed)
        tearDown()
    }

    @Test func loadReturnsManagedForUnrecognizedString() {
        defaults.set("nonsense", forKey: ModePreferenceStorage.key)
        #expect(storage.load() == .managed)
        tearDown()
    }

    @Test func bookmarkAndModeStoragesShareSuiteWithoutCollision() {
        let bookmark = BookmarkStorage(defaults: defaults)
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        bookmark.save(payload)
        storage.save(.readOnly)
        #expect(bookmark.load() == payload)
        #expect(storage.load() == .readOnly)
        tearDown()
    }

    private func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
