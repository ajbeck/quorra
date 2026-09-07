import Foundation
import QuorraIPC

public enum ProfileSignInOperationError: LocalizedError, Equatable {
    case profilesNotReady
    case profileNotFound(String)
    case profileDoesNotUseIdentityCenter(String)
    case sessionNotFound(String)
    case invalidSession(String)
    case operationNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .profilesNotReady:
            return "Quorra is still loading profiles. Try again in a moment."
        case .profileNotFound(let name):
            return "No profile matches ‘\(name)’."
        case .profileDoesNotUseIdentityCenter(let name):
            return "Profile ‘\(name)’ does not use IAM Identity Center."
        case .sessionNotFound(let name):
            return "The IAM Identity Center session ‘\(name)’ is not configured."
        case .invalidSession(let name):
            return "The IAM Identity Center session ‘\(name)’ is missing a valid start URL or region."
        case .operationNotFound(let id):
            return "No sign-in operation matches ‘\(id.uuidString)’."
        }
    }
}

/// Owns asynchronous IAM Identity Center sign-in operations initiated over IPC.
///
/// The app remains responsible for browser presentation and Keychain writes. IPC
/// clients receive only operation state and poll using the returned identifier.
@MainActor
public final class ProfileSignInOperationCoordinator {
    private struct StoredOperation {
        var record: QuorraProfileSignInOperationRecord
        var task: Task<Void, Never>?
    }

    private let profilesModel: ProfilesModel
    private let credentialsModel: CredentialsModel
    private var operations: [UUID: StoredOperation] = [:]
    private let completedOperationRetention: TimeInterval = 15 * 60

    public init(profilesModel: ProfilesModel, credentialsModel: CredentialsModel) {
        self.profilesModel = profilesModel
        self.credentialsModel = credentialsModel
    }

    public func begin(profileName: String) throws -> QuorraProfileSignInOperationRecord {
        guard case .loaded = profilesModel.loadState else {
            throw ProfileSignInOperationError.profilesNotReady
        }
        guard let profile = profilesModel.findProfile(named: profileName) else {
            throw ProfileSignInOperationError.profileNotFound(profileName)
        }
        guard let sessionName = profile.profile.ssoSession, !sessionName.isEmpty else {
            throw ProfileSignInOperationError.profileDoesNotUseIdentityCenter(profileName)
        }
        guard let session = profilesModel.findSession(named: sessionName) else {
            throw ProfileSignInOperationError.sessionNotFound(sessionName)
        }
        guard let startURLString = session.session?.ssoStartUrl,
              let startURL = URL(string: startURLString),
              let region = session.session?.ssoRegion,
              !region.isEmpty else {
            throw ProfileSignInOperationError.invalidSession(sessionName)
        }

        pruneCompletedOperations()

        let operationID = UUID()
        let now = Date()
        let record = QuorraProfileSignInOperationRecord(
            id: operationID,
            profileName: profileName,
            sessionName: sessionName,
            state: .starting,
            startedAt: now,
            updatedAt: now
        )
        operations[operationID] = StoredOperation(record: record)

        let scopes = session.session?.ssoRegistrationScopes ?? ["sso:account:access"]
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await credentialsModel.signIn(
                sessionName: sessionName,
                startUrl: startURL,
                region: region,
                scopes: scopes
            )
            complete(operationID, with: result)
        }
        operations[operationID]?.task = task
        return record
    }

    public func operation(id: UUID) throws -> QuorraProfileSignInOperationRecord {
        pruneCompletedOperations()
        guard var stored = operations[id] else {
            throw ProfileSignInOperationError.operationNotFound(id)
        }
        if stored.record.state == .starting,
           credentialsModel.inFlight[stored.record.sessionName] != nil {
            stored.record = replacing(stored.record, state: .waitingForUser)
            operations[id] = stored
        }
        return stored.record
    }

    public func cancel(id: UUID) async throws -> QuorraProfileSignInOperationRecord {
        guard var stored = operations[id] else {
            throw ProfileSignInOperationError.operationNotFound(id)
        }
        guard !stored.record.state.isTerminal else { return stored.record }

        stored.task?.cancel()
        await credentialsModel.cancelSignIn(sessionName: stored.record.sessionName)
        stored.record = replacing(stored.record, state: .cancelled)
        operations[id] = stored
        return stored.record
    }

    private func complete(_ id: UUID, with result: CredentialsSignInResult) {
        guard var stored = operations[id], !stored.record.state.isTerminal else { return }
        switch result {
        case .succeeded:
            stored.record = replacing(stored.record, state: .succeeded)
        case .cancelled:
            stored.record = replacing(stored.record, state: .cancelled)
        case .failed(let error):
            stored.record = replacing(
                stored.record,
                state: .failed,
                message: error.localizedDescription
            )
        }
        stored.task = nil
        operations[id] = stored
    }

    private func replacing(
        _ record: QuorraProfileSignInOperationRecord,
        state: QuorraProfileSignInState,
        message: String? = nil
    ) -> QuorraProfileSignInOperationRecord {
        QuorraProfileSignInOperationRecord(
            id: record.id,
            profileName: record.profileName,
            sessionName: record.sessionName,
            state: state,
            message: message,
            startedAt: record.startedAt,
            updatedAt: Date()
        )
    }

    private func pruneCompletedOperations(now: Date = Date()) {
        operations = operations.filter { _, stored in
            !stored.record.state.isTerminal
                || now.timeIntervalSince(stored.record.updatedAt) < completedOperationRetention
        }
    }
}
