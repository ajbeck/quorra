import Foundation
import SwiftData
import Testing
@testable import QuorraAppLogic

@Suite("Metadata models")
struct MetadataModelTests {
    @Test func folder_assignments_have_stable_object_keys() {
        let key = MetadataFolderAssignment.objectKey(
            kind: .profile,
            objectID: "ac:cp:org_admin"
        )

        #expect(key == "profile:ac:cp:org_admin")
    }

    @Test func imds_endpoint_definitions_expose_loopback_urls() {
        let endpoint = IMDSEndpointDefinition(
            name: "Terraform",
            profileName: "ac:cp:org_admin",
            port: 9678
        )

        #expect(endpoint.endpointURL?.absoluteString == "http://127.0.0.1:9678")
    }

    @Test func imds_endpoint_log_limit_matches_product_decision() {
        #expect(IMDSEndpointLogStore.maxEntriesPerEndpoint == 1_000)
    }

    @MainActor
    @Test func imds_endpoint_log_batches_prune_only_the_oldest_entries() throws {
        let container = try QuorraMetadataSchema.makeContainer(inMemory: true)
        let context = container.mainContext
        let endpointID = UUID()
        let entries = (0..<8).map { index in
            IMDSEndpointLogEntry(
                endpointID: endpointID,
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                method: "GET",
                path: "/request/\(index)",
                statusCode: 200
            )
        }

        try IMDSEndpointLogStore.append(entries, in: context, limit: 3)

        let endpointIDString = endpointID.uuidString
        let descriptor = FetchDescriptor<IMDSEndpointLogEntry>(
            predicate: #Predicate { $0.endpointIDString == endpointIDString },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        let retained = try context.fetch(descriptor)
        #expect(retained.map(\.path) == ["/request/7", "/request/6", "/request/5"])
    }

    @MainActor
    @Test func imds_endpoint_log_buffer_writes_one_batch_at_its_size_limit() throws {
        let container = try QuorraMetadataSchema.makeContainer(inMemory: true)
        let context = container.mainContext
        let endpointID = UUID()
        let buffer = IMDSEndpointLogBuffer(
            context: context,
            maximumBatchSize: 3,
            flushDelay: .seconds(60)
        )

        for index in 0..<2 {
            buffer.append(requestLog(index: index), endpointID: endpointID)
        }
        #expect(try context.fetchCount(FetchDescriptor<IMDSEndpointLogEntry>()) == 0)

        buffer.append(requestLog(index: 2), endpointID: endpointID)
        #expect(try context.fetchCount(FetchDescriptor<IMDSEndpointLogEntry>()) == 3)
    }

    @MainActor
    @Test func deleting_an_imds_endpoint_removes_its_log_history_only() throws {
        let container = try QuorraMetadataSchema.makeContainer(inMemory: true)
        let context = container.mainContext
        let removedEndpointID = UUID()
        let keptEndpointID = UUID()
        try IMDSEndpointLogStore.append([
            logEntry(endpointID: removedEndpointID, index: 0),
            logEntry(endpointID: removedEndpointID, index: 1),
            logEntry(endpointID: keptEndpointID, index: 2),
        ], in: context)

        try IMDSEndpointLogStore.deleteAll(endpointID: removedEndpointID, in: context)
        try context.save()

        let retained = try context.fetch(FetchDescriptor<IMDSEndpointLogEntry>())
        #expect(retained.count == 1)
        #expect(retained.first?.endpointIDString == keptEndpointID.uuidString)
    }

    private func requestLog(index: Int) -> IMDSRequestLog {
        IMDSRequestLog(
            timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
            method: "GET",
            path: "/request/\(index)",
            client: "test",
            status: 200
        )
    }

    private func logEntry(endpointID: UUID, index: Int) -> IMDSEndpointLogEntry {
        IMDSEndpointLogEntry(
            endpointID: endpointID,
            timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
            method: "GET",
            path: "/request/\(index)",
            statusCode: 200
        )
    }
}
