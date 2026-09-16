import Foundation
import QuorraAppLogic

/// A row in the object list: a value snapshot of a store record, keyed by the detail selection it opens.
enum ObjectListItem: Identifiable, Hashable {
    case session(SessionListItem)
    case profile(ProfileListItem)
    case imds(IMDSEndpointListItem)

    var id: String {
        switch self {
        case .session(let session):
            return "session:\(session.name)"
        case .profile(let profile):
            return "profile:\(profile.name)"
        case .imds(let endpoint):
            return "imds:\(endpoint.id)"
        }
    }

    var detailSelection: DetailSelection {
        switch self {
        case .session(let session):
            return .session(name: session.name)
        case .profile(let profile):
            return .profile(name: profile.name)
        case .imds(let endpoint):
            return .imds(endpointID: endpoint.endpointID)
        }
    }

    var searchText: String {
        switch self {
        case .session(let session):
            return "session \(session.name) \(session.startURL) \(session.region)"
        case .profile(let profile):
            return "profile \(profile.name) \(profile.sessionName ?? "") \(profile.accountID) \(profile.roleName)"
        case .imds(let endpoint):
            return "imds endpoint \(endpoint.title) \(endpoint.profileName) \(endpoint.subtitle) \(endpoint.state.searchText)"
        }
    }
}

struct SessionListItem: Hashable {
    let name: String
    let startURL: String
    let region: String
    let profileCount: Int
}

struct ProfileListItem: Hashable {
    let name: String
    let sessionName: String?
    let accountID: String
    let roleName: String
}

struct IMDSEndpointListItem: Identifiable, Hashable {
    let endpointID: String
    let name: String?
    let profileName: String
    let port: Int?
    let state: IMDSEndpointState

    var id: String { endpointID }
    var isDefault: Bool { DefaultIMDSEndpoint.matches(endpointID: endpointID) }

    var title: String {
        if let name {
            return name
        }
        if let port = state.port ?? port {
            return "localhost:\(port)"
        }
        return profileName
    }

    var subtitle: String {
        if let port = state.port ?? port {
            return "localhost:\(port) -> \(profileName)"
        }
        return "serving \(profileName)"
    }
}

private extension IMDSEndpointState {
    var searchText: String {
        switch self {
        case .inactive:
            return "imds inactive"
        case .starting(let port):
            return "imds starting localhost 127.0.0.1 \(port)"
        case .active(let port):
            return "imds active live localhost 127.0.0.1 \(port)"
        case .failed(let port, let message):
            return "imds failed localhost 127.0.0.1 \(port) \(message)"
        }
    }
}
