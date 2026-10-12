import Foundation
import SwiftData

/// A saved AWS Client VPN profile. The `.ovpn` text can hold the client's private key, so it lives
/// only in the Keychain, keyed by this record's stable ID; this record keeps what the window and
/// menu bar show without reading it.
@Model
public final class ClientVPNProfileDefinition {
    public var stableIDString: String
    public var name: String
    /// The server Quorra connects to, in place of the profile's own.
    public var endpoint: String
    /// The server named in the imported profile.
    public var profileEndpoint: String
    public var fileName: String
    public var port: Int
    public var transportRawValue: String
    public var usesBrowserSignIn: Bool
    public var isFavorite: Bool
    public var createdAt: Date
    public var updatedAt: Date

    @Relationship(deleteRule: .nullify, inverse: \DatabaseConnectionDefinition.clientVPN)
    public var connections: [DatabaseConnectionDefinition]

    public init(id: UUID = UUID(), name: String, endpoint: String, profile: ClientVPNProfile, fileName: String) {
        stableIDString = id.uuidString
        self.name = name
        self.endpoint = endpoint
        profileEndpoint = ""
        self.fileName = ""
        port = 0
        transportRawValue = ""
        usesBrowserSignIn = false
        isFavorite = false
        createdAt = .now
        updatedAt = .now
        connections = []
        apply(profile, fileName: fileName)
    }

    public var stableID: UUID {
        UUID(uuidString: stableIDString) ?? UUID()
    }

    public var transport: ClientVPNProfile.Transport {
        ClientVPNProfile.Transport(rawValue: transportRawValue) ?? .udp
    }

    /// Copies what Quorra shows about an imported profile.
    func apply(_ profile: ClientVPNProfile, fileName: String) {
        profileEndpoint = profile.endpoint
        self.fileName = fileName
        port = profile.port
        transportRawValue = profile.transport.rawValue
        usesBrowserSignIn = profile.usesBrowserSignIn
        updatedAt = .now
    }
}
