import Foundation

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
}
