import Foundation
import QuorraAppLogic
import Testing

struct AWSFolderStorageTests {
    let defaults: UserDefaults
    let storage: AWSFolderStorage
    let suiteName = "dev.ajbeck.quorra.tests.\(UUID().uuidString)"

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        storage = AWSFolderStorage(defaults: defaults)
    }

    @Test func defaultsToTheAWSFolderInHome() {
        #expect(storage.load() == FileManager.default.homeDirectoryForCurrentUser.appending(path: ".aws", directoryHint: .isDirectory))
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func aChosenFolderRoundTrips() {
        let folder = URL(filePath: "/Users/example/work aws", directoryHint: .isDirectory)
        storage.save(folder)
        #expect(storage.load() == folder)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func aBookmarkFromTheSandboxedAppBecomesAPath() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AWSFolderStorageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bookmark = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: "dev.ajbeck.quorra.awsFolderBookmark")

        #expect(storage.load().standardizedFileURL.path == folder.standardizedFileURL.path)
        #expect(defaults.object(forKey: "dev.ajbeck.quorra.awsFolderBookmark") == nil)
        #expect(defaults.string(forKey: AWSFolderStorage.key) != nil)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func anUnresolvableBookmarkFallsBackToTheDefaultFolder() {
        defaults.set(Data([0x01, 0x02, 0x03]), forKey: "dev.ajbeck.quorra.awsFolderBookmark")

        #expect(storage.load() == AWSFolderStorage.defaultFolder)
        #expect(defaults.object(forKey: "dev.ajbeck.quorra.awsFolderBookmark") == nil)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
