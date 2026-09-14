import Foundation
import QuorraAppLogic

enum SourceSelection: Hashable, Sendable {
    case all
    case sessions
    case profiles
    case imdsEndpoints

    var title: String {
        switch self {
        case .all: return "All"
        case .sessions: return "Sessions"
        case .profiles: return "Profiles"
        case .imdsEndpoints: return "IMDS Endpoints"
        }
    }

    var objectKind: MetadataObjectKind? {
        switch self {
        case .all:
            return nil
        case .sessions:
            return .session
        case .profiles:
            return .profile
        case .imdsEndpoints:
            return .imdsEndpoint
        }
    }
}
