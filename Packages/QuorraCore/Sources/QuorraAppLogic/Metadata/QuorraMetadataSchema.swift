import SwiftData

public enum QuorraMetadataSchema {
    public static var modelTypes: [any PersistentModel.Type] {
        [
        MetadataFolder.self,
        MetadataFolderAssignment.self,
        IMDSEndpointDefinition.self,
        IMDSEndpointLogEntry.self
        ]
    }

    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(modelTypes)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
