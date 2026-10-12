import Foundation
import SwiftData

public enum QuorraMetadataSchema {
    public static var modelTypes: [any PersistentModel.Type] {
        [
        SessionDefinition.self,
        ProfileDefinition.self,
        IMDSEndpointDefinition.self,
        IMDSEndpointLogEntry.self
        ]
    }

    /// SwiftData places its unnamed store in the app's App Group container, so through 1.1
    /// Quorra's data lived at this path inside the group's container.
    static let appGroupIdentifier = "9GEBAJV9R4.quorra"
    static let groupStorePath = "Library/Application Support/default.store"

    /// SQLite keeps uncommitted pages in these companions, so they travel with the store.
    static let sqliteFileSuffixes = ["", "-wal", "-shm"]

    /// `Quorra/Quorra.store` in Application Support. SwiftData's unnamed default store
    /// is `default.store` directly in Application Support, a name any app may use.
    public static func storeURL(applicationSupportDirectory: URL = .applicationSupportDirectory) -> URL {
        applicationSupportDirectory.appending(path: "Quorra/Quorra.store")
    }

    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(modelTypes)
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            let url = storeURL()
            if let legacyURL = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
                .appending(path: groupStorePath) {
                try copyStore(from: legacyURL, to: url)
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            configuration = ModelConfiguration(schema: schema, url: url)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Copies a closed SQLite store and its companion files, leaving the original for an
    /// older Quorra. Does nothing when the source is missing or the destination exists.
    static func copyStore(from source: URL, to destination: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: source.path),
              !fileManager.fileExists(atPath: destination.path) else { return }

        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        for suffix in sqliteFileSuffixes {
            let sourceFile = URL(filePath: source.path + suffix)
            guard fileManager.fileExists(atPath: sourceFile.path) else { continue }
            try fileManager.copyItem(at: sourceFile, to: URL(filePath: destination.path + suffix))
        }
    }
}
