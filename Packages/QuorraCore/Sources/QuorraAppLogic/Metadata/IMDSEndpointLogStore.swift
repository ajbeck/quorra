import Foundation
import SwiftData

public enum IMDSEndpointLogStore {
    public static let maxEntriesPerEndpoint = 1_000

    @MainActor
    public static func append(_ entry: IMDSEndpointLogEntry, in context: ModelContext) throws {
        try append([entry], in: context)
    }

    @MainActor
    public static func append(
        _ entries: [IMDSEndpointLogEntry],
        in context: ModelContext,
        limit: Int = maxEntriesPerEndpoint
    ) throws {
        guard !entries.isEmpty else { return }

        for entry in entries {
            context.insert(entry)
        }
        context.processPendingChanges()

        for endpointID in Set(entries.map(\.endpointID)) {
            try prune(endpointID: endpointID, in: context, limit: limit)
        }
        try context.save()
    }

    @MainActor
    public static func prune(endpointID: UUID, in context: ModelContext, limit: Int = maxEntriesPerEndpoint) throws {
        let endpointIDString = endpointID.uuidString
        let predicate = #Predicate<IMDSEndpointLogEntry> { $0.endpointIDString == endpointIDString }
        let countDescriptor = FetchDescriptor<IMDSEndpointLogEntry>(predicate: predicate)
        let excessCount = try context.fetchCount(countDescriptor) - max(0, limit)
        guard excessCount > 0 else { return }

        var descriptor = FetchDescriptor<IMDSEndpointLogEntry>(
            predicate: #Predicate { $0.endpointIDString == endpointIDString },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        descriptor.fetchLimit = excessCount

        for entry in try context.fetch(descriptor) {
            context.delete(entry)
        }
    }

    @MainActor
    public static func deleteAll(endpointID: UUID, in context: ModelContext) throws {
        let endpointIDString = endpointID.uuidString
        let descriptor = FetchDescriptor<IMDSEndpointLogEntry>(
            predicate: #Predicate { $0.endpointIDString == endpointIDString }
        )
        for entry in try context.fetch(descriptor) {
            context.delete(entry)
        }
    }
}

@MainActor
public final class IMDSEndpointLogBuffer {
    public static let maximumBatchSize = 50
    public static let flushDelay: Duration = .seconds(1)

    private let context: ModelContext
    private let maximumBatchSize: Int
    private let flushDelay: Duration
    private var pendingEntries: [IMDSEndpointLogEntry] = []
    private var flushTask: Task<Void, Never>?

    public convenience init(context: ModelContext) {
        self.init(
            context: context,
            maximumBatchSize: Self.maximumBatchSize,
            flushDelay: Self.flushDelay
        )
    }

    init(context: ModelContext, maximumBatchSize: Int, flushDelay: Duration) {
        self.context = context
        self.maximumBatchSize = max(1, maximumBatchSize)
        self.flushDelay = flushDelay
    }

    public func append(_ log: IMDSRequestLog, endpointID: UUID) {
        pendingEntries.append(IMDSEndpointLogEntry(
            id: log.id,
            endpointID: endpointID,
            timestamp: log.timestamp,
            method: log.method,
            path: log.path,
            statusCode: log.status,
            client: log.client
        ))

        if pendingEntries.count >= maximumBatchSize {
            flush()
        } else if flushTask == nil {
            scheduleFlush()
        }
    }

    public func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingEntries.isEmpty else { return }

        let entries = pendingEntries
        pendingEntries.removeAll(keepingCapacity: true)
        try? IMDSEndpointLogStore.append(entries, in: context)
    }

    private func scheduleFlush() {
        flushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.flushDelay)
            } catch {
                return
            }
            self.flushTask = nil
            self.flush()
        }
    }
}
