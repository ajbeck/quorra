import Foundation
import SwiftData

@Model
final class MetadataFolder {
    var stableIDString: String
    var kindRawValue: String
    var name: String
    var sortIndex: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        kind: MetadataObjectKind,
        name: String,
        sortIndex: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.stableIDString = id.uuidString
        self.kindRawValue = kind.rawValue
        self.name = name
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var stableID: UUID {
        get { UUID(uuidString: stableIDString) ?? UUID() }
        set {
            stableIDString = newValue.uuidString
            updatedAt = .now
        }
    }

    var kind: MetadataObjectKind {
        get { MetadataObjectKind(rawValue: kindRawValue) ?? .profile }
        set {
            kindRawValue = newValue.rawValue
            updatedAt = .now
        }
    }
}

@Model
final class MetadataFolderAssignment {
    var objectKey: String
    var stableIDString: String
    var objectKindRawValue: String
    var objectID: String
    var folderIDString: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        objectKind: MetadataObjectKind,
        objectID: String,
        folderID: UUID,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.stableIDString = id.uuidString
        self.objectKindRawValue = objectKind.rawValue
        self.objectID = objectID
        self.objectKey = Self.objectKey(kind: objectKind, objectID: objectID)
        self.folderIDString = folderID.uuidString
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var stableID: UUID {
        get { UUID(uuidString: stableIDString) ?? UUID() }
        set {
            stableIDString = newValue.uuidString
            updatedAt = .now
        }
    }

    var folderID: UUID {
        get { UUID(uuidString: folderIDString) ?? UUID() }
        set {
            folderIDString = newValue.uuidString
            updatedAt = .now
        }
    }

    var objectKind: MetadataObjectKind {
        get { MetadataObjectKind(rawValue: objectKindRawValue) ?? .profile }
        set {
            objectKindRawValue = newValue.rawValue
            objectKey = Self.objectKey(kind: newValue, objectID: objectID)
            updatedAt = .now
        }
    }

    func move(to folderID: UUID) {
        self.folderIDString = folderID.uuidString
        updatedAt = .now
    }

    static func objectKey(kind: MetadataObjectKind, objectID: String) -> String {
        "\(kind.rawValue):\(objectID)"
    }
}

@Model
final class IMDSEndpointDefinition {
    var stableIDString: String
    var port: Int
    var name: String
    var profileName: String
    var bindAddress: String
    var allowsIMDSv1: Bool
    var hopLimit: Int
    var folderIDString: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        profileName: String,
        port: Int = 9678,
        bindAddress: String = "127.0.0.1",
        allowsIMDSv1: Bool = true,
        hopLimit: Int = 2,
        folderID: UUID? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.stableIDString = id.uuidString
        self.name = name
        self.profileName = profileName
        self.port = port
        self.bindAddress = bindAddress
        self.allowsIMDSv1 = allowsIMDSv1
        self.hopLimit = hopLimit
        self.folderIDString = folderID?.uuidString
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var stableID: UUID {
        get { UUID(uuidString: stableIDString) ?? UUID() }
        set {
            stableIDString = newValue.uuidString
            updatedAt = .now
        }
    }

    var folderID: UUID? {
        get {
            guard let folderIDString else { return nil }
            return UUID(uuidString: folderIDString)
        }
        set {
            folderIDString = newValue?.uuidString
            updatedAt = .now
        }
    }

    var endpointURL: URL? {
        URL(string: "http://\(bindAddress):\(port)")
    }
}

@Model
final class IMDSEndpointLogEntry {
    var stableIDString: String
    var endpointIDString: String
    var timestamp: Date
    var method: String
    var path: String
    var statusCode: Int
    var client: String?
    var userAgent: String?
    var message: String?

    init(
        id: UUID = UUID(),
        endpointID: UUID,
        timestamp: Date = .now,
        method: String,
        path: String,
        statusCode: Int,
        client: String? = nil,
        userAgent: String? = nil,
        message: String? = nil
    ) {
        self.stableIDString = id.uuidString
        self.endpointIDString = endpointID.uuidString
        self.timestamp = timestamp
        self.method = method
        self.path = path
        self.statusCode = statusCode
        self.client = client
        self.userAgent = userAgent
        self.message = message
    }

    var stableID: UUID {
        get { UUID(uuidString: stableIDString) ?? UUID() }
        set { stableIDString = newValue.uuidString }
    }

    var endpointID: UUID {
        get { UUID(uuidString: endpointIDString) ?? UUID() }
        set { endpointIDString = newValue.uuidString }
    }
}
