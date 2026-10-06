import Foundation
import Testing
@testable import QuorraAppLogic

struct SandboxContainerTests {
    let home: URL
    let defaults: UserDefaults
    let suiteName = "dev.ajbeck.quorra.tests.\(UUID().uuidString)"

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "SandboxContainerTests-\(UUID().uuidString)")
        for file in SandboxContainer.preferenceFiles(home: home) {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        defaults = UserDefaults(suiteName: suiteName)!
    }

    private func writePreferences(_ values: [String: Any], to file: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).write(to: file)
    }

    @Test func containersLiveInTheUsersLibrary() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        #expect(SandboxContainer.dataDirectory(home: home).path == "/Users/someone/Library/Containers/dev.ajbeck.quorra/Data")
        #expect(SandboxContainer.groupDirectory(home: home).path == "/Users/someone/Library/Group Containers/9GEBAJV9R4.quorra")
    }

    @Test func prefersTheNewestStoreLocation() {
        let urls = SandboxContainer.storeURLs(home: home).map(\.path)
        #expect(urls == [
            home.appending(path: "Library/Containers/dev.ajbeck.quorra/Data/Library/Application Support/Quorra/Quorra.store").path,
            home.appending(path: "Library/Group Containers/9GEBAJV9R4.quorra/Library/Application Support/default.store").path,
            home.appending(path: "Library/Containers/dev.ajbeck.quorra/Data/Library/Application Support/default.store").path
        ])
    }

    @Test func importsPreferencesOnceWithTheAppGroupWinning() throws {
        let files = SandboxContainer.preferenceFiles(home: home)
        try writePreferences([
            "dev.ajbeck.quorra.managedMode": "readOnly",
            "dev.ajbeck.quorra.menu-bar-only": false
        ], to: files[0])
        try writePreferences(["dev.ajbeck.quorra.menu-bar-only": true], to: files[1])
        defaults.set("managed", forKey: "dev.ajbeck.quorra.managedMode")

        SandboxContainer.importPreferences(home: home, into: defaults)
        #expect(defaults.string(forKey: "dev.ajbeck.quorra.managedMode") == "readOnly")
        #expect(defaults.bool(forKey: "dev.ajbeck.quorra.menu-bar-only"))

        defaults.set("managed", forKey: "dev.ajbeck.quorra.managedMode")
        SandboxContainer.importPreferences(home: home, into: defaults)
        #expect(defaults.string(forKey: "dev.ajbeck.quorra.managedMode") == "managed")
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func missingContainersCountAsImported() {
        SandboxContainer.importPreferences(home: home, into: defaults)
        #expect(defaults.bool(forKey: SandboxContainer.preferencesImportedKey))
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func anUnreadableFileIsRetried() throws {
        let files = SandboxContainer.preferenceFiles(home: home)
        try writePreferences(["dev.ajbeck.quorra.managedMode": "readOnly"], to: files[0])
        try Data("not a property list".utf8).write(to: files[1])

        SandboxContainer.importPreferences(home: home, into: defaults)

        #expect(!defaults.bool(forKey: SandboxContainer.preferencesImportedKey))
        #expect(defaults.string(forKey: "dev.ajbeck.quorra.managedMode") == nil)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
