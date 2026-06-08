import SwiftData

enum QuorraMetadataSchema {
    static let modelTypes: [any PersistentModel.Type] = [
        MetadataFolder.self,
        MetadataFolderAssignment.self,
        IMDSEndpointDefinition.self,
        IMDSEndpointLogEntry.self
    ]

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(modelTypes)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

