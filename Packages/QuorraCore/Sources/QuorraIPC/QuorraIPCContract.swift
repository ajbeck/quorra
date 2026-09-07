import Foundation

public enum QuorraIPCProtocol {
    public static let currentVersion = 1
    public static let minimumSupportedVersion = 1

    public static let teamIdentifier = "9GEBAJV9R4"
    public static let appIdentifier = "dev.ajbeck.quorra"
    public static let cliIdentifier = "dev.ajbeck.quorra.cli"
    public static let appGroupIdentifier = "9GEBAJV9R4.quorra"
}

public enum QuorraIPCOperation: String, Codable, CaseIterable, Sendable {
    case handshake
    case appTerminate = "app.terminate"
    case profileSignInStart = "profiles.sign-in.start"
    case profileSignInStatus = "profiles.sign-in.status"
    case profileSignInCancel = "profiles.sign-in.cancel"
    case imdsList = "imds.list"
    case imdsStatus = "imds.status"
    case imdsStart = "imds.start"
    case imdsStop = "imds.stop"
    case imdsSwitchProfile = "imds.switch-profile"
}

public enum QuorraProfileSignInState: String, Codable, Sendable {
    case starting
    case waitingForUser = "waiting_for_user"
    case succeeded
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .starting, .waitingForUser:
            return false
        case .succeeded, .failed, .cancelled:
            return true
        }
    }
}

public struct QuorraProfileSignInOperationRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let profileName: String
    public let sessionName: String
    public let state: QuorraProfileSignInState
    public let message: String?
    public let startedAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        profileName: String,
        sessionName: String,
        state: QuorraProfileSignInState,
        message: String? = nil,
        startedAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.profileName = profileName
        self.sessionName = sessionName
        self.state = state
        self.message = message
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }
}

public struct QuorraIPCAcknowledgement: Codable, Equatable, Sendable {
    public init() {}
}

public struct QuorraIPCRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let operation: QuorraIPCOperation
    public let arguments: [String: String]

    public init(
        protocolVersion: Int = QuorraIPCProtocol.currentVersion,
        requestID: UUID = UUID(),
        operation: QuorraIPCOperation,
        arguments: [String: String] = [:]
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.operation = operation
        self.arguments = arguments
    }
}

public struct QuorraIPCResponse: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case success
        case failure
    }

    public let protocolVersion: Int
    public let requestID: UUID
    public let status: Status
    public let payload: Data?
    public let error: QuorraIPCErrorPayload?

    public init(
        protocolVersion: Int = QuorraIPCProtocol.currentVersion,
        requestID: UUID,
        status: Status,
        payload: Data? = nil,
        error: QuorraIPCErrorPayload? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.status = status
        self.payload = payload
        self.error = error
    }

    public static func success<Payload: Encodable & Sendable>(
        requestID: UUID,
        payload: Payload
    ) throws -> QuorraIPCResponse {
        QuorraIPCResponse(
            requestID: requestID,
            status: .success,
            payload: try QuorraIPCCodec.encode(payload)
        )
    }

    public static func failure(
        requestID: UUID,
        code: QuorraIPCErrorCode,
        message: String
    ) -> QuorraIPCResponse {
        QuorraIPCResponse(
            requestID: requestID,
            status: .failure,
            error: QuorraIPCErrorPayload(code: code, message: message)
        )
    }

    public func decodePayload<Payload: Decodable & Sendable>(
        as type: Payload.Type = Payload.self
    ) throws -> Payload {
        guard let payload else {
            throw QuorraIPCCodecError.missingPayload
        }
        return try QuorraIPCCodec.decode(type, from: payload)
    }
}

public enum QuorraIPCErrorCode: String, Codable, Sendable {
    case incompatibleProtocol = "incompatible_protocol"
    case invalidRequest = "invalid_request"
    case notReady = "not_ready"
    case notFound = "not_found"
    case operationFailed = "operation_failed"
}

public struct QuorraIPCErrorPayload: Codable, Equatable, Sendable {
    public let code: QuorraIPCErrorCode
    public let message: String

    public init(code: QuorraIPCErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public struct QuorraIPCServerInfo: Codable, Equatable, Sendable {
    public let appVersion: String
    public let protocolVersion: Int
    public let minimumSupportedProtocolVersion: Int
    public let capabilities: [QuorraIPCOperation]

    public init(
        appVersion: String,
        protocolVersion: Int = QuorraIPCProtocol.currentVersion,
        minimumSupportedProtocolVersion: Int = QuorraIPCProtocol.minimumSupportedVersion,
        capabilities: [QuorraIPCOperation] = QuorraIPCOperation.allCases
    ) {
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
        self.minimumSupportedProtocolVersion = minimumSupportedProtocolVersion
        self.capabilities = capabilities
    }
}

public enum QuorraIMDSEndpointStatus: String, Codable, Sendable {
    case inactive
    case starting
    case running
    case failed
}

public struct QuorraIMDSEndpointRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let profileName: String?
    public let servedProfileName: String?
    public let bindAddress: String
    public let configuredPort: Int
    public let boundPort: Int?
    public let status: QuorraIMDSEndpointStatus
    public let failureMessage: String?
    public let isDefault: Bool

    public init(
        id: String,
        name: String,
        profileName: String?,
        servedProfileName: String? = nil,
        bindAddress: String,
        configuredPort: Int,
        boundPort: Int?,
        status: QuorraIMDSEndpointStatus,
        failureMessage: String? = nil,
        isDefault: Bool
    ) {
        self.id = id
        self.name = name
        self.profileName = profileName
        self.servedProfileName = servedProfileName
        self.bindAddress = bindAddress
        self.configuredPort = configuredPort
        self.boundPort = boundPort
        self.status = status
        self.failureMessage = failureMessage
        self.isDefault = isDefault
    }
}

public enum QuorraIPCCodec {
    public static func encode<Value: Encodable & Sendable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<Value: Decodable & Sendable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        try JSONDecoder().decode(type, from: data)
    }
}

public enum QuorraIPCCodecError: Error, Equatable {
    case missingPayload
}
