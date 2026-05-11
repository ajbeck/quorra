import Foundation
import Testing
import AWSConfigINI
@testable import quorra

@MainActor
struct AppModelTests {
    let suiteName: String
    let defaults: UserDefaults
    let bookmarkStorage: BookmarkStorage
    let modeStorage: ModePreferenceStorage

    init() {
        let name = "dev.ajbeck.quorra.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        self.suiteName = name
        self.defaults = defaults
        self.bookmarkStorage = BookmarkStorage(defaults: defaults)
        self.modeStorage = ModePreferenceStorage(defaults: defaults)
    }

    @Test func initLoadsManagedByDefault() {
        let model = AppModel(bookmarkStorage: bookmarkStorage, modeStorage: modeStorage)
        #expect(model.mode == .managed)
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

        // Verify a fresh model reading from the same suite also sees the persisted value.
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

        let phaseUnchanged = if case .error(.folderMissing) = model.phase { true } else { false }
        #expect(phaseUnchanged)
        #expect(model.mode == .readOnly)
        tearDown()
    }

    @Test func resetToSetupPreservesMode() async {
        let model = AppModel(bookmarkStorage: bookmarkStorage, modeStorage: modeStorage)
        await model.setMode(.readOnly)
        await model.resetToSetup()

        // Mode is a user-level preference — it survives a folder reset.
        #expect(model.mode == .readOnly)
        tearDown()
    }

    private func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
