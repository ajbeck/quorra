import Foundation
import QuorraAppLogic

enum SourceSelection: Hashable, Sendable {
    case all
    case sessions
    case profiles
    case imdsEndpoints
    case folder(kind: MetadataObjectKind, folderID: UUID, name: String)

    var title: String {
        switch self {
        case .all: return "All"
        case .sessions: return "Sessions"
        case .profiles: return "Profiles"
        case .imdsEndpoints: return "IMDS Endpoints"
        case .folder(_, _, let name): return name
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
        case .folder(let kind, _, _):
            return kind
        }
    }

    var folderID: UUID? {
        if case .folder(_, let folderID, _) = self {
            return folderID
        }
        return nil
    }
}
