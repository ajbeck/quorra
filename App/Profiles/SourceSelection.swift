import Foundation
import QuorraAppLogic

enum SourceSelection: Hashable, Sendable, CaseIterable {
    case sessions
    case profiles
    case imdsEndpoints
    case databaseConnections
    case databaseCredentials

    var title: String {
        switch self {
        case .sessions: return "Sessions"
        case .profiles: return "Profiles"
        case .imdsEndpoints: return "IMDS Endpoints"
        case .databaseConnections: return "Connections"
        case .databaseCredentials: return "Credentials"
        }
    }

    var systemImage: String {
        switch self {
        case .sessions: return "cloud"
        case .profiles: return "key"
        case .imdsEndpoints: return "antenna.radiowaves.left.and.right"
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
        case .databaseConnections, .databaseCredentials:
            return nil
        }
    }
}
