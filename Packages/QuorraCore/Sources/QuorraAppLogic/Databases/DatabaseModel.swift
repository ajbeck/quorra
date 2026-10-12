import DatabaseProxy
import Foundation
import IAMIdentityCenter
import Observation
import SwiftData

/// Runs database connections: one `ProxyCoordinator` for the app, its live statuses, and each
/// connection's log. Role credentials come from Identity Center through `roleCredentials`.
@MainActor
@Observable
public final class DatabaseModel {
    public typealias RoleCredentialFetch = @Sendable (_ session: String, _ account: String, _ role: String, _ region: String) async throws -> IAMIdentityCenter.RoleCredentials
    /// Readies the network a connection's upstream needs, such as its Client VPN, before Start or Test.
    public typealias NetworkPreparation = @MainActor (DatabaseConnectionDefinition) async throws -> Void

    /// The connection a Start or Test is working on, so views can disable repeated clicks.
    public private(set) var workingConnectionIDs: Set<UUID> = []
    @ObservationIgnored private var proxy: ProxyCoordinator!
    @ObservationIgnored public let secrets: DatabaseSecrets
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let prepareNetwork: NetworkPreparation?
    @ObservationIgnored private var pendingLog: [DatabaseConnectionLogEntry] = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    public init(context: ModelContext, secrets: DatabaseSecrets, prepareNetwork: NetworkPreparation? = nil, roleCredentials: @escaping RoleCredentialFetch) {
        self.context = context
        self.secrets = secrets
        self.prepareNetwork = prepareNetwork
        let diagnostics = DiagnosticLog { [weak self] entry in
            guard let connectionID = entry.connectionID else { return }
            Task { @MainActor in self?.record(entry, connectionID: connectionID) }
        }
        let provider = IdentityCenterRoleCredentials(fetch: roleCredentials)
        let passwordLogin: @Sendable (UUID) async throws -> DatabaseLogin = { [weak self] credentialID in
            guard let self else { throw ConfigurationError.missingCredential }
            return try await self.login(credentialID: credentialID)
        }
        proxy = ProxyCoordinator(credentials: provider, diagnostics: diagnostics, passwordLogin: passwordLogin)
    }

    public func status(for connectionID: UUID) -> ProxyEndpointStatus {
        proxy.statuses[connectionID] ?? ProxyEndpointStatus()
    }

    public func isActive(_ connectionID: UUID) -> Bool {
        proxy.isActive(connectionID)
    }

    /// True while any connection has failed, for the menu bar's attention badge.
    public var hasFailure: Bool {
        proxy.statuses.values.contains { $0.state == .failed }
    }

    /// Readies the network, checks the upstream, then listens on the connection's local port.
    /// Upstream failures are shown in the connection's status; every failure is thrown so the
    /// caller can show it too.
    public func start(_ connection: DatabaseConnectionDefinition) async throws {
        let id = connection.stableID
        guard !workingConnectionIDs.contains(id) else { return }
        workingConnectionIDs.insert(id)
        defer { workingConnectionIDs.remove(id) }
        try await prepareNetwork?(connection)
        let summary = DatabaseStore.summary(for: connection)
        let password = summary.draft.localAuthentication == .generatedPassword
            ? try await secrets.localPassword(forConnection: id) : nil
        try await proxy.start(summary, binding: Self.binding(for: connection), password: password)
    }

    /// Signs in to the upstream once and disconnects, without listening locally.
    public func test(_ connection: DatabaseConnectionDefinition) async throws {
        let id = connection.stableID
        guard !workingConnectionIDs.contains(id) else { return }
        workingConnectionIDs.insert(id)
        defer { workingConnectionIDs.remove(id) }
        try await prepareNetwork?(connection)
        try await proxy.test(DatabaseStore.summary(for: connection), binding: Self.binding(for: connection))
    }

    public func stop(_ connectionID: UUID) async {
        await proxy.stop(connectionID)
    }

    public func shutdown() async {
        await proxy.shutdown()
        flushLog()
    }

    /// The local password clients use for a generated-password connection.
    public func localPassword(for connection: DatabaseConnectionDefinition) async throws -> String {
        try await secrets.localPassword(forConnection: connection.stableID)
    }

    static func binding(for connection: DatabaseConnectionDefinition) -> DatabaseRoleBinding? {
        guard connection.authentication == .awsIAM, let coordinates = connection.profile?.credentialCoordinates else { return nil }
        return DatabaseRoleBinding(sessionName: coordinates.session, accountID: coordinates.account,
                                   roleName: coordinates.role, region: coordinates.region)
    }

    private func login(credentialID: UUID) async throws -> DatabaseLogin {
        let idString = credentialID.uuidString
        var descriptor = FetchDescriptor<DatabaseCredentialDefinition>(predicate: #Predicate { $0.stableIDString == idString })
        descriptor.fetchLimit = 1
        guard let credential = try context.fetch(descriptor).first else { throw ConfigurationError.missingCredential }
        let username = credential.username
        return DatabaseLogin(username: username, password: try await secrets.password(forCredential: credentialID))
    }

    // MARK: - Log

    private func record(_ entry: DiagnosticEntry, connectionID: UUID) {
        pendingLog.append(DatabaseConnectionLogEntry(entry, connectionID: connectionID))
        if pendingLog.count >= 50 {
            flushLog()
        } else if flushTask == nil {
            flushTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.flushTask = nil
                self?.flushLog()
            }
        }
    }

    /// Writes buffered log entries now. Views and tests call this to see the latest events.
    public func flushLog() {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingLog.isEmpty else { return }
        let entries = pendingLog
        pendingLog.removeAll(keepingCapacity: true)
        try? DatabaseConnectionLogStore.append(entries, in: context)
    }
}

private struct IdentityCenterRoleCredentials: DatabaseRoleCredentialProviding {
    let fetch: DatabaseModel.RoleCredentialFetch

    func credentials(for binding: DatabaseRoleBinding) async throws -> RoleCredentials {
        try await fetch(binding.sessionName, binding.accountID, binding.roleName, binding.region)
    }
}
