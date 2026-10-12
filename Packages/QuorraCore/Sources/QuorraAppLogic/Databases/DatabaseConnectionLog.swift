import DatabaseProxy
import Foundation
import SwiftData

/// One proxy event for a database connection. Entries carry only event names, client IDs,
/// counts and error codes; never SQL, usernames, tokens or connection strings.
@Model
public final class DatabaseConnectionLogEntry {
    public var stableIDString: String
    public var connectionIDString: String
    public var timestamp: Date
    public var event: String
    public var level: String
    public var clientIDString: String?
    public var count: Int?
    public var failureCode: String?

    public init(_ entry: DiagnosticEntry, connectionID: UUID) {
        stableIDString = entry.id.uuidString
        connectionIDString = connectionID.uuidString
        timestamp = entry.timestamp
        event = entry.event.rawValue
        level = entry.level
        clientIDString = entry.clientID?.uuidString
        count = entry.count
        failureCode = entry.failure?.code
    }
}

@MainActor
public enum DatabaseConnectionLogStore {
    public static let maxEntriesPerConnection = 1_000

    public static func append(_ entries: [DatabaseConnectionLogEntry], in context: ModelContext, limit: Int = maxEntriesPerConnection) throws {
        guard !entries.isEmpty else { return }
        for entry in entries {
            context.insert(entry)
        }
        context.processPendingChanges()
        for connectionID in Set(entries.map(\.connectionIDString)) {
            let countDescriptor = FetchDescriptor<DatabaseConnectionLogEntry>(predicate: #Predicate { $0.connectionIDString == connectionID })
            let excess = try context.fetchCount(countDescriptor) - max(0, limit)
            guard excess > 0 else { continue }
            var oldest = FetchDescriptor<DatabaseConnectionLogEntry>(
                predicate: #Predicate { $0.connectionIDString == connectionID },
                sortBy: [SortDescriptor(\.timestamp)]
            )
            oldest.fetchLimit = excess
            for entry in try context.fetch(oldest) {
                context.delete(entry)
            }
        }
        try context.save()
    }

    public static func deleteAll(connectionID: UUID, in context: ModelContext) throws {
        let idString = connectionID.uuidString
        for entry in try context.fetch(FetchDescriptor<DatabaseConnectionLogEntry>(predicate: #Predicate { $0.connectionIDString == idString })) {
            context.delete(entry)
        }
        try context.save()
    }
}
