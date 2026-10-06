import Foundation
import Testing
@testable import QuorraAppLogic

struct MetadataStoreLocationTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "MetadataStoreLocationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func write(_ contents: String, to name: String) throws {
        try Data(contents.utf8).write(to: directory.appending(path: name))
    }

    private func contents(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @Test func storeLivesInAQuorraFolder() {
        let url = QuorraMetadataSchema.storeURL(applicationSupportDirectory: directory)
        #expect(url == directory.appending(path: "Quorra/Quorra.store"))
    }

    @Test func copiesTheStoreWithItsCompanionFiles() throws {
        try write("store", to: "default.store")
        try write("wal", to: "default.store-wal")
        try write("shm", to: "default.store-shm")
        let destination = QuorraMetadataSchema.storeURL(applicationSupportDirectory: directory)

        try QuorraMetadataSchema.copyStore(from: directory.appending(path: "default.store"), to: destination)

        #expect(try contents(of: destination) == "store")
        #expect(try contents(of: URL(filePath: destination.path + "-wal")) == "wal")
        #expect(try contents(of: URL(filePath: destination.path + "-shm")) == "shm")
        #expect(try contents(of: directory.appending(path: "default.store")) == "store")
    }

    @Test func keepsAnExistingStore() throws {
        try write("legacy", to: "default.store")
        let destination = QuorraMetadataSchema.storeURL(applicationSupportDirectory: directory)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("current".utf8).write(to: destination)

        try QuorraMetadataSchema.copyStore(from: directory.appending(path: "default.store"), to: destination)

        #expect(try contents(of: destination) == "current")
        #expect(try contents(of: directory.appending(path: "default.store")) == "legacy")
    }

    @Test func ignoresAMissingSource() throws {
        let destination = QuorraMetadataSchema.storeURL(applicationSupportDirectory: directory)

        try QuorraMetadataSchema.copyStore(from: directory.appending(path: "default.store"), to: destination)

        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
