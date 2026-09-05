import AWSConfigINI
import Foundation
import QuorraAppLogic
import Testing

@MainActor
struct AppModelTests {
    let suiteName: String
    let defaults: UserDefaults
    let bookmarkStorage: BookmarkStorage
    let modeStorage: ModePreferenceStorage

    init() {
        let name = "dev.ajbeck.quorra.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        suiteName = name
        self.defaults = defaults
        bookmarkStorage = BookmarkStorage(defaults: defaults)
        modeStorage = ModePreferenceStorage(defaults: defaults)
    }

    @Test func initWithoutBookmarkBeginsInSetup() {
        let model = AppModel(bookmarkStorage: bookmarkStorage, modeStorage: modeStorage)

        guard case .setup = model.phase else {
            Issue.record("Expected setup phase when no bookmark is stored")
            tearDown()
            return
        }
        tearDown()
    }

    @Test func initWithBookmarkBeginsRestoring() {
        bookmarkStorage.save(Data([0x01, 0x02, 0x03]))

        let model = AppModel(bookmarkStorage: bookmarkStorage, modeStorage: modeStorage)

        guard case .restoring = model.phase else {
            Issue.record("Expected restoring phase while a stored bookmark is resolved")
            tearDown()
            return
        }
        tearDown()
    }

    @Test func initLoadsPersistedReadOnly() {
        modeStorage.save(.readOnly)
        let model = AppModel(bookmarkStorage: bookmarkStorage, modeStorage: modeStorage)
        #expect(model.mode == .readOnly)
        tearDown()
    }

    @Test func setModePersistsAndPublishes() async {
        let model = AppModel(bookmarkStorage: bookmarkStorage, modeStorage: modeStorage)
        await model.setMode(.readOnly)
        #expect(model.mode == .readOnly)

        let model2 = AppModel(bookmarkStorage: bookmarkStorage, modeStorage: modeStorage)
        #expect(model2.mode == .readOnly)
        tearDown()
    }

    @Test func setModeInErrorPhaseSucceeds() async {
        let model = AppModel(
            bookmarkStorage: bookmarkStorage,
            modeStorage: modeStorage,
            initialPhase: .error(.folderMissing)
        )

        await model.setMode(.readOnly)

        #expect(model.mode == .readOnly)
        tearDown()
    }

    @Test func resetToSetupPreservesMode() async {
        modeStorage.save(.readOnly)
        let model = AppModel(bookmarkStorage: bookmarkStorage, modeStorage: modeStorage)

        await model.resetToSetup()

        #expect(model.mode == .readOnly)
        tearDown()
    }

    private func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
