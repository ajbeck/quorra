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

    func startEndpoint(forProfile name: String, port: Int = 9678) {
        endpointsByProfile[name] = .starting(port: port)

        // Temporary UI-only transition until the IMDS server runtime owns this path.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.finishStartingEndpoint(forProfile: name)
        }
    }

    func stopEndpoint(forProfile name: String) {
        endpointsByProfile[name] = .inactive
    }

    func retryEndpoint(forProfile name: String) {
        let port = state(forProfile: name).port ?? 9678
        startEndpoint(forProfile: name, port: port)
    }

    private func finishStartingEndpoint(forProfile name: String) {
        guard case .starting(let port) = state(forProfile: name) else { return }
        endpointsByProfile[name] = .active(port: port)
    }
}

enum IMDSEndpointState: Hashable, Sendable {
    case inactive
    case starting(port: Int)
    case active(port: Int)
    case failed(port: Int, message: String)

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    var isStarting: Bool {
        if case .starting = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var port: Int? {
        switch self {
        case .inactive:
            return nil
        case .starting(let port), .active(let port), .failed(let port, _):
            return port
        }
    }

    var failureMessage: String? {
        if case .failed(_, let message) = self { return message }
        return nil
    }
}
