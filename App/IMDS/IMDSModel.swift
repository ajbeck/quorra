import Foundation
import AWSConfigINI
import IAMIdentityCenter
import Observation
import QuorraAppLogic
import QuorraProfiles
import SwiftData

@Observable
@MainActor
final class IMDSModel {
    typealias RequestRecorder = @MainActor (_ endpointID: String, _ log: IMDSRequestLog) -> Void

    private static let defaultEndpointRunningKey = "dev.ajbeck.quorra.default-imds-endpoint.should-run"

    private(set) var endpointsByEndpointID: [String: IMDSEndpointState] = [:]
    private(set) var runtimeInfoByEndpointID: [String: IMDSRuntimeInfo] = [:]
    @ObservationIgnored private var serversByEndpointID: [String: LocalIMDSServer] = [:]
    @ObservationIgnored private var logBuffersByEndpointID: [String: IMDSEndpointLogBuffer] = [:]
    @ObservationIgnored private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
    }

    var shouldRestoreDefaultEndpoint: Bool {
        preferences.bool(forKey: Self.defaultEndpointRunningKey)
    }

    func rememberDefaultEndpointShouldRun(_ shouldRun: Bool) {
        preferences.set(shouldRun, forKey: Self.defaultEndpointRunningKey)
    }

    func state(forEndpointID endpointID: String) -> IMDSEndpointState {
        endpointsByEndpointID[endpointID] ?? .inactive
    }

    func runtimeInfo(forEndpointID endpointID: String) -> IMDSRuntimeInfo? {
        runtimeInfoByEndpointID[endpointID]
    }

    func setState(_ state: IMDSEndpointState, forEndpointID endpointID: String) {
        endpointsByEndpointID[endpointID] = state
    }

    func startEndpoint(
        endpointID: String,
        for node: ProfileNode,
        credentialsModel: CredentialsModel,
        bindAddress: String = "127.0.0.1",
        port: Int = 9678,
        allowsIMDSv1: Bool = true,
        logContext: ModelContext? = nil,
        requestRecorder: RequestRecorder? = nil
    ) async {
        guard let sessionName = node.profile.ssoSession,
              let accountId = node.profile.ssoAccountId,
              let roleName = node.profile.ssoRoleName else {
            endpointsByEndpointID[endpointID] = .failed(port: port, message: "Profile is missing SSO account, role, or session metadata.")
            return
        }

        await startEndpoint(
            endpointID: endpointID,
            profileName: node.id,
            sessionName: sessionName,
            accountId: accountId,
            roleName: roleName,
            region: node.profile.region ?? "us-east-1",
            credentialsModel: credentialsModel,
            bindAddress: bindAddress,
            port: port,
            allowsIMDSv1: allowsIMDSv1,
            logContext: logContext,
            requestRecorder: requestRecorder
        )
    }

    func startEndpoint(
        endpointID: String,
        profileName: String,
        sessionName: String,
        accountId: String,
        roleName: String,
        region: String,
        credentialsModel: CredentialsModel,
        bindAddress: String = "127.0.0.1",
        port: Int = 9678,
        allowsIMDSv1: Bool = true,
        logContext: ModelContext? = nil,
        requestRecorder: RequestRecorder? = nil
    ) async {
        endpointsByEndpointID[endpointID] = .starting(port: port)

        do {
            let initialCredentials = try await credentialsModel.liveCredentials(
                forSession: sessionName,
                accountId: accountId,
                roleName: roleName,
                region: region
            )
            let servedProfile = IMDSServedProfile(
                profileName: profileName,
                sessionName: sessionName,
                accountId: accountId,
                roleName: roleName,
                region: region
            )

            stopEndpoints(onPort: port, except: endpointID)
            serversByEndpointID[endpointID]?.stop()
            configureLogBuffer(forEndpointID: endpointID, context: logContext)

            let server = LocalIMDSServer(
                bindAddress: bindAddress,
                port: port,
                servedProfile: servedProfile,
                allowsIMDSv1: allowsIMDSv1,
                initialCredentials: initialCredentials,
                credentialProvider: {
                    try await credentialsModel.liveCredentials(
                        forSession: sessionName,
                        accountId: accountId,
                        roleName: roleName,
                        region: region
                    )
                },
                onRequest: { [weak self] log in
                    Task { @MainActor in
                        self?.recordRequest(log, forEndpointID: endpointID)
                        if let endpointUUID = UUID(uuidString: endpointID) {
                            self?.logBuffersByEndpointID[endpointID]?.append(log, endpointID: endpointUUID)
                        }
                        requestRecorder?(endpointID, log)
                    }
                },
                onFailure: { [weak self] message in
                    Task { @MainActor in
                        self?.markEndpointFailed(forEndpointID: endpointID, port: port, message: message)
                    }
                }
            )

            serversByEndpointID[endpointID] = server
            runtimeInfoByEndpointID[endpointID] = IMDSRuntimeInfo(servedProfileName: profileName)
            try await server.start()
            let boundPort = server.boundPort

            // Avoid flashing through the starting state when credentials and the
            // listener are both immediately available. The server is already ready;
            // this only gives the UI a stable, readable transition before "Running".
            try await Task.sleep(for: .milliseconds(180))
            guard serversByEndpointID[endpointID] === server else { return }

            endpointsByEndpointID[endpointID] = .active(port: boundPort)
            publishPort(boundPort)
        } catch is CancellationError {
            stopEndpoint(forEndpointID: endpointID)
        } catch {
            serversByEndpointID[endpointID]?.stop()
            serversByEndpointID[endpointID] = nil
            flushAndRemoveLogBuffer(forEndpointID: endpointID)
            runtimeInfoByEndpointID[endpointID] = nil
            endpointsByEndpointID[endpointID] = .failed(port: port, message: displayMessage(for: error))
            unpublishPortIfNoActiveServers()
        }
    }

    func stopEndpoint(forEndpointID endpointID: String) {
        serversByEndpointID[endpointID]?.stop()
        serversByEndpointID[endpointID] = nil
        flushAndRemoveLogBuffer(forEndpointID: endpointID)
        runtimeInfoByEndpointID[endpointID] = nil
        endpointsByEndpointID[endpointID] = .inactive
        unpublishPortIfNoActiveServers()
    }

    /// Replaces the identity behind a running endpoint without closing its listener.
    /// The existing profile remains live until credentials for the replacement are ready.
    @discardableResult
    func switchEndpointProfile(
        endpointID: String,
        to node: ProfileNode,
        credentialsModel: CredentialsModel
    ) async throws -> Bool {
        guard let server = serversByEndpointID[endpointID],
              state(forEndpointID: endpointID).isActive,
              let sessionName = node.profile.ssoSession,
              let accountId = node.profile.ssoAccountId,
              let roleName = node.profile.ssoRoleName else {
            return false
        }

        let region = node.profile.region ?? "us-east-1"
        let credentials = try await credentialsModel.liveCredentials(
            forSession: sessionName,
            accountId: accountId,
            roleName: roleName,
            region: region
        )
        let servedProfile = IMDSServedProfile(
            profileName: node.id,
            sessionName: sessionName,
            accountId: accountId,
            roleName: roleName,
            region: region
        )
        server.updateServedProfile(
            servedProfile,
            credentials: credentials,
            credentialProvider: {
                try await credentialsModel.liveCredentials(
                    forSession: sessionName,
                    accountId: accountId,
                    roleName: roleName,
                    region: region
                )
            }
        )

        if let runtime = runtimeInfoByEndpointID[endpointID] {
            runtimeInfoByEndpointID[endpointID] = IMDSRuntimeInfo(
                startedAt: runtime.startedAt,
                servedProfileName: node.id,
                requestCount: runtime.requestCount,
                activity: runtime.activity
            )
        }
        return true
    }

    private func stopEndpoints(onPort port: Int, except keptEndpointID: String) {
        for endpointID in Array(serversByEndpointID.keys) where endpointID != keptEndpointID {
            guard endpointsByEndpointID[endpointID]?.port == port else { continue }
            stopEndpoint(forEndpointID: endpointID)
        }
        for endpointID in Array(endpointsByEndpointID.keys) where endpointID != keptEndpointID {
            if case .active(let activePort) = endpointsByEndpointID[endpointID], activePort == port {
                endpointsByEndpointID[endpointID] = .inactive
            }
        }
    }

    private func recordRequest(_ log: IMDSRequestLog, forEndpointID endpointID: String) {
        guard var runtime = runtimeInfoByEndpointID[endpointID] else { return }
        runtime.requestCount += 1
        runtime.activity.insert(log, at: 0)
        if runtime.activity.count > 50 {
            runtime.activity.removeLast(runtime.activity.count - 50)
        }
        runtimeInfoByEndpointID[endpointID] = runtime
    }

    private func configureLogBuffer(forEndpointID endpointID: String, context: ModelContext?) {
        flushAndRemoveLogBuffer(forEndpointID: endpointID)
        if let context {
            logBuffersByEndpointID[endpointID] = IMDSEndpointLogBuffer(context: context)
        }
    }

    private func flushAndRemoveLogBuffer(forEndpointID endpointID: String) {
        logBuffersByEndpointID[endpointID]?.flush()
        logBuffersByEndpointID[endpointID] = nil
    }

    private func markEndpointFailed(forEndpointID endpointID: String, port: Int, message: String) {
        serversByEndpointID[endpointID]?.stop()
        serversByEndpointID[endpointID] = nil
        flushAndRemoveLogBuffer(forEndpointID: endpointID)
        runtimeInfoByEndpointID[endpointID] = nil
        endpointsByEndpointID[endpointID] = .failed(port: port, message: message)
        unpublishPortIfNoActiveServers()
    }

    private func displayMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private func publishPort(_ port: Int) {
        do {
            let directory = try portPublicationDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "\(port)\n".write(to: directory.appending(path: "imds.port"), atomically: true, encoding: .utf8)
        } catch {
            // Failure to publish the helper file should not stop the already-running server.
        }
    }

    private func unpublishPortIfNoActiveServers() {
        guard serversByEndpointID.isEmpty else { return }
        guard let directory = try? portPublicationDirectory() else { return }
        try? FileManager.default.removeItem(at: directory.appending(path: "imds.port"))
    }

    private func portPublicationDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appending(path: "Quorra", directoryHint: .isDirectory)
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
