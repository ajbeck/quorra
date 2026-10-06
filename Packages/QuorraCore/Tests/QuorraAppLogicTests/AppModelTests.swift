import AWSConfigINI
import Foundation
import QuorraAppLogic
import Testing

@MainActor
struct AppModelTests {
    let suiteName: String
    let defaults: UserDefaults
    let folderStorage: AWSFolderStorage
    let modeStorage: ModePreferenceStorage

    init() {
        let name = "dev.ajbeck.quorra.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        suiteName = name
        self.defaults = defaults
        folderStorage = AWSFolderStorage(defaults: defaults)
        modeStorage = ModePreferenceStorage(defaults: defaults)
    }

    @Test func aFreshInstallReadsTheDefaultFolderWithoutExporting() {
        let model = AppModel(folderStorage: folderStorage, modeStorage: modeStorage)

        #expect(model.folderURL == AWSFolderStorage.defaultFolder)
        #expect(model.mode == .readOnly)
        tearDown()
    }

    @Test func initLoadsPersistedManagedMode() {
        modeStorage.save(.managed)
        let model = AppModel(folderStorage: folderStorage, modeStorage: modeStorage)
        #expect(model.mode == .managed)
        tearDown()
    }

    @Test func setModePersistsAndPublishes() async {
        let model = AppModel(folderStorage: folderStorage, modeStorage: modeStorage)
        await model.setMode(.managed)
        #expect(model.mode == .managed)

        let model2 = AppModel(folderStorage: folderStorage, modeStorage: modeStorage)
        #expect(model2.mode == .managed)
        tearDown()
    }

    @Test func chooseFolderPersistsAndPublishes() {
        let folder = URL(filePath: "/Users/example/work-aws", directoryHint: .isDirectory)
        let model = AppModel(folderStorage: folderStorage, modeStorage: modeStorage)

        model.chooseFolder(folder)

        #expect(model.folderURL == folder)
        #expect(AppModel(folderStorage: folderStorage, modeStorage: modeStorage).folderURL == folder)
        tearDown()
    }

    private func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
