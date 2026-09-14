import Foundation
import SwiftData

@Model
public final class IMDSEndpointDefinition {
    public var stableIDString: String
    public var port: Int
    public var name: String
    public var profileName: String
    public var bindAddress: String
    public var allowsIMDSv1: Bool
    public var hopLimit: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        profileName: String,
        port: Int = 9678,
        bindAddress: String = "127.0.0.1",
        allowsIMDSv1: Bool = true,
        hopLimit: Int = 2,
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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var stableID: UUID {
        get { UUID(uuidString: stableIDString) ?? UUID() }
        set {
            stableIDString = newValue.uuidString
            updatedAt = .now
        }
    }

    public var endpointURL: URL? {
        URL(string: "http://\(bindAddress):\(port)")
    }
}

@Model
public final class IMDSEndpointLogEntry {
    public var stableIDString: String
    public var endpointIDString: String
    public var timestamp: Date
    public var method: String
    public var path: String
    public var statusCode: Int
    public var client: String?
    public var userAgent: String?
    public var message: String?

    public init(
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

    public var stableID: UUID {
        get { UUID(uuidString: stableIDString) ?? UUID() }
        set { stableIDString = newValue.uuidString }
    }

    public var endpointID: UUID {
        get { UUID(uuidString: endpointIDString) ?? UUID() }
        set { endpointIDString = newValue.uuidString }
    }
}
