import Foundation
import QuorraAppLogic

enum SourceSelection: Hashable, Sendable, CaseIterable {
    case sessions
    case profiles
    case imdsEndpoints
    // Sidebar and arrow-key order follow the case order.
    case clientVPN
    case databaseConnections
    case databaseCredentials

    var title: String {
        switch self {
        case .sessions: return "Sessions"
        case .profiles: return "Profiles"
        case .imdsEndpoints: return "IMDS Endpoints"
        case .clientVPN: return "Client VPN"
        case .databaseConnections: return "Connections"
        case .databaseCredentials: return "Credentials"
        }
    }

    var systemImage: String {
        switch self {
        case .sessions: return "cloud"
        case .profiles: return "key"
        case .imdsEndpoints: return "antenna.radiowaves.left.and.right"
        case .clientVPN: return "network.badge.shield.half.filled"
        case .databaseConnections: return "cylinder.split.1x2"
        case .databaseCredentials: return "person.badge.key"
        }
    }

    var objectKind: MetadataObjectKind? {
        switch self {
        case .sessions:
            return .session
        case .profiles:
            return .profile
        case .imdsEndpoints:
            return .imdsEndpoint
        case .clientVPN, .databaseConnections, .databaseCredentials:
            return nil
        }
    }
}
