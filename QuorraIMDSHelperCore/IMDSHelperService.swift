import Darwin
import Foundation

public enum IMDSHelperServiceState: Equatable {
    case disabled
    case enabling
    case enabled
    case disabling
    case failed(String)
}

public enum IMDSHelperServiceError: LocalizedError, Equatable {
    case operationInProgress
    case requiresRoot
    case rollbackFailed(primary: String, rollback: String)

    public var errorDescription: String? {
        switch self {
        case .operationInProgress:
            return "Another metadata endpoint operation is already in progress."
        case .requiresRoot:
            return "The metadata endpoint helper must run as root."
        case .rollbackFailed(let primary, let rollback):
            return "Metadata endpoint startup failed (\(primary)); cleanup also failed (\(rollback))."
        }
    }
}

@MainActor
public final class IMDSHelperService {
    private let backendProbe: any IMDSBackendProbing
    private let aliasManager: any InterfaceAliasManaging
    private let relay: any IMDSTCPRelaying
    private let isPrivileged: () -> Bool

    public private(set) var state: IMDSHelperServiceState = .disabled

    public convenience init() {
        self.init(
            backendProbe: NetworkIMDSBackendProbe(),
            aliasManager: InterfaceAliasManager(system: DarwinInterfaceAliasSystem()),
            relay: IMDSTCPRelay(),
            isPrivileged: { geteuid() == 0 }
        )
    }

    public init(
        backendProbe: any IMDSBackendProbing,
        aliasManager: any InterfaceAliasManaging,
        relay: any IMDSTCPRelaying,
        isPrivileged: @escaping () -> Bool
    ) {
        self.backendProbe = backendProbe
        self.aliasManager = aliasManager
        self.relay = relay
        self.isPrivileged = isPrivileged
    }

    public func enable() async throws {
        if state == .enabled {
            return
        }
        try requireIdleState()
        guard isPrivileged() else {
            throw recordFailure(IMDSHelperServiceError.requiresRoot)
        }

        state = .enabling
        do {
            try await backendProbe.probe()
            _ = try aliasManager.enable()
            do {
                try await relay.start()
            } catch {
                do {
                    _ = try aliasManager.disable()
                } catch let rollbackError {
                    throw IMDSHelperServiceError.rollbackFailed(
                        primary: error.localizedDescription,
                        rollback: rollbackError.localizedDescription
                    )
                }
                throw error
            }
            state = .enabled
        } catch {
            throw recordFailure(error)
        }
    }

    public func disable() throws {
        try requireIdleState()
        guard isPrivileged() else {
            throw recordFailure(IMDSHelperServiceError.requiresRoot)
        }

        state = .disabling
        relay.stop()
        do {
            _ = try aliasManager.disable()
            state = .disabled
        } catch {
            throw recordFailure(error)
        }
    }

    private func requireIdleState() throws {
        switch state {
        case .enabling, .disabling:
            throw IMDSHelperServiceError.operationInProgress
        case .disabled, .enabled, .failed:
            break
        }
    }

    @discardableResult
    private func recordFailure(_ error: Error) -> Error {
        state = .failed(error.localizedDescription)
        return error
    }
}
