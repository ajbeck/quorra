import Observation

@Observable
@MainActor
final class IMDSModel {
    private(set) var endpointsByProfile: [String: IMDSEndpointState] = [:]

    func state(forProfile name: String) -> IMDSEndpointState {
        endpointsByProfile[name] ?? .inactive
    }

    func setState(_ state: IMDSEndpointState, forProfile name: String) {
        endpointsByProfile[name] = state
    }
}

enum IMDSEndpointState: Hashable, Sendable {
    case inactive
    case active(port: Int)

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    var port: Int? {
        if case .active(let port) = self { return port }
        return nil
    }
}
