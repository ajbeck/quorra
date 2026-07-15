import CoreTransferable
import UniformTypeIdentifiers

struct MetadataObjectDragPayload: Codable, Hashable, Sendable, Transferable {
    let kind: MetadataObjectKind
    let objectID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .quorraMetadataObject)
    }
}

extension UTType {
    static let quorraMetadataObject = UTType(exportedAs: "dev.ajbeck.quorra.metadata-object")
}
