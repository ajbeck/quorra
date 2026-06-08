import Foundation
import SwiftData

enum IMDSEndpointLogStore {
    static let maxEntriesPerEndpoint = 1_000

    @MainActor
    static func append(_ entry: IMDSEndpointLogEntry, in context: ModelContext) throws {
        context.insert(entry)
        try prune(endpointID: entry.endpointID, in: context)
        try context.save()
    }

    @MainActor
    static func prune(endpointID: UUID, in context: ModelContext, limit: Int = maxEntriesPerEndpoint) throws {
        let endpointIDString = endpointID.uuidString
        let descriptor = FetchDescriptor<IMDSEndpointLogEntry>(
            predicate: #Predicate { $0.endpointIDString == endpointIDString },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        let entries = try context.fetch(descriptor)
        guard entries.count > limit else { return }

        for entry in entries.dropFirst(limit) {
            context.delete(entry)
        }
    }
}
