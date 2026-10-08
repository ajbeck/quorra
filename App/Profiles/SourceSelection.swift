import Foundation
import QuorraAppLogic

enum SourceSelection: Hashable, Sendable, CaseIterable {
    case sessions
    case profiles
    case imdsEndpoints

    var title: String {
        switch self {
        case .sessions: return "Sessions"
        case .profiles: return "Profiles"
        case .imdsEndpoints: return "IMDS Endpoints"
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
        }
    }
}
