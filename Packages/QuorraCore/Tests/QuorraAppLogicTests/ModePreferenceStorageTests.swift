import AWSConfigINI
import Foundation
import QuorraAppLogic
import Testing

struct ModePreferenceStorageTests {
    let defaults: UserDefaults
    let storage: ModePreferenceStorage
    let suiteName: String

    init() {
        let name = "dev.ajbeck.quorra.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        suiteName = name
        self.defaults = defaults
        storage = ModePreferenceStorage(defaults: defaults)
    }

    @Test func loadReturnsReadOnlyWhenNoValuePresent() {
        #expect(storage.load() == .readOnly)
    }

    @Test func saveAndLoadRoundTripManaged() {
        storage.save(.managed)
        #expect(storage.load() == .managed)
        tearDown()
    }

    @Test func clearRemovesValueAndLoadFallsBack() {
        storage.save(.managed)
        storage.clear()
        #expect(storage.load() == .readOnly)
        tearDown()
    }

    @Test func loadReturnsManagedForUnrecognizedString() {
        defaults.set("nonsense", forKey: ModePreferenceStorage.key)
        #expect(storage.load() == .managed)
        tearDown()
    }

    @Test func folderAndModeStoragesShareSuiteWithoutCollision() {
        let folderStorage = AWSFolderStorage(defaults: defaults)
        let folder = URL(filePath: "/Users/example/work-aws", directoryHint: .isDirectory)
        folderStorage.save(folder)

        storage.save(.managed)

        #expect(folderStorage.load() == folder)
        #expect(storage.load() == .managed)
        tearDown()
    }

    private func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
