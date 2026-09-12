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
    private var operationGeneration = 0

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

        operationGeneration += 1
        let operation = operationGeneration
        state = .enabling
        var aliasIsActive = false
        do {
            try await backendProbe.probe()
            try requireCurrent(operation)
            _ = try aliasManager.enable()
            aliasIsActive = true
            try await relay.start()
            try requireCurrent(operation)
            state = .enabled
        } catch {
            guard operation == operationGeneration else {
                throw CancellationError()
            }
            if aliasIsActive {
                do {
                    _ = try aliasManager.disable()
                } catch let rollbackError {
                    throw recordFailure(IMDSHelperServiceError.rollbackFailed(
                        primary: error.localizedDescription,
                        rollback: rollbackError.localizedDescription
                    ))
                }
            }
            throw recordFailure(error)
        }
    }

    public func disable() throws {
        guard isPrivileged() else {
            throw recordFailure(IMDSHelperServiceError.requiresRoot)
        }
        if state == .disabling {
            throw IMDSHelperServiceError.operationInProgress
        }

        operationGeneration += 1
        state = .disabling
        relay.stop()
        do {
            _ = try aliasManager.disable()
            state = .disabled
        } catch {
            throw recordFailure(error)
        }
    }

    private func requireCurrent(_ operation: Int) throws {
        guard operation == operationGeneration else {
            throw CancellationError()
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
