import Foundation
import AWSConfigINI
import IAMIdentityCenter
import Observation

@Observable
@MainActor
final class IMDSModel {
    typealias RequestRecorder = @MainActor (_ endpointID: String, _ log: IMDSRequestLog) -> Void

    private(set) var endpointsByProfile: [String: IMDSEndpointState] = [:]
    private(set) var runtimeInfoByProfile: [String: IMDSRuntimeInfo] = [:]
    @ObservationIgnored private var serversByProfile: [String: LocalIMDSServer] = [:]

    func state(forProfile name: String) -> IMDSEndpointState {
        endpointsByProfile[name] ?? .inactive
    }

    func state(forEndpointID endpointID: String, profileName: String? = nil) -> IMDSEndpointState {
        if let state = endpointsByProfile[endpointID] {
            return state
        }
        if let profileName, profileName != endpointID {
            return endpointsByProfile[profileName] ?? .inactive
        }
        return .inactive
    }

    func runtimeInfo(forProfile name: String) -> IMDSRuntimeInfo? {
        runtimeInfoByProfile[name]
    }

    func runtimeInfo(forEndpointID endpointID: String, profileName: String? = nil) -> IMDSRuntimeInfo? {
        if let runtimeInfo = runtimeInfoByProfile[endpointID] {
            return runtimeInfo
        }
        if let profileName, profileName != endpointID {
            return runtimeInfoByProfile[profileName]
        }
        return nil
    }

    func setState(_ state: IMDSEndpointState, forProfile name: String) {
        endpointsByProfile[name] = state
    }

    func setState(_ state: IMDSEndpointState, forEndpointID endpointID: String) {
        endpointsByProfile[endpointID] = state
    }

    func startEndpoint(
        for node: ProfileNode,
        credentialsModel: CredentialsModel,
        port: Int = 9678,
        requestRecorder: RequestRecorder? = nil
    ) async {
        await startEndpoint(
            endpointID: node.id,
            for: node,
            credentialsModel: credentialsModel,
            port: port,
            requestRecorder: requestRecorder
        )
    }

    func startEndpoint(
        endpointID: String,
        for node: ProfileNode,
        credentialsModel: CredentialsModel,
        port: Int = 9678,
        requestRecorder: RequestRecorder? = nil
    ) async {
        guard let sessionName = node.profile.ssoSession,
              let accountId = node.profile.ssoAccountId,
              let roleName = node.profile.ssoRoleName else {
            endpointsByProfile[endpointID] = .failed(port: port, message: "Profile is missing SSO account, role, or session metadata.")
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
            port: port,
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
        port: Int = 9678,
        requestRecorder: RequestRecorder? = nil
    ) async {
        endpointsByProfile[endpointID] = .starting(port: port)

        do {
            let credentials = try await credentialsModel.liveCredentials(
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
                region: region,
                credentials: credentials
            )

            stopEndpoints(onPort: port, except: endpointID)
            serversByProfile[endpointID]?.stop()

            let server = LocalIMDSServer(
                port: port,
                servedProfile: servedProfile,
                onRequest: { [weak self] log in
                    Task { @MainActor in
                        self?.recordRequest(log, forEndpointID: endpointID)
                        requestRecorder?(endpointID, log)
                    }
                },
                onFailure: { [weak self] message in
                    Task { @MainActor in
                        self?.markEndpointFailed(forEndpointID: endpointID, port: port, message: message)
                    }
                }
            )

            serversByProfile[endpointID] = server
            runtimeInfoByProfile[endpointID] = IMDSRuntimeInfo(servedProfileName: profileName)
            try await server.start()
            let boundPort = server.boundPort
            endpointsByProfile[endpointID] = .active(port: boundPort)
            publishPort(boundPort)
        } catch is CancellationError {
            stopEndpoint(forEndpointID: endpointID)
        } catch {
            serversByProfile[endpointID]?.stop()
            serversByProfile[endpointID] = nil
            runtimeInfoByProfile[endpointID] = nil
            endpointsByProfile[endpointID] = .failed(port: port, message: displayMessage(for: error))
            unpublishPortIfNoActiveServers()
        }
    }

    func startEndpoint(forProfile name: String, port: Int = 9678) {
        startEndpoint(forEndpointID: name, port: port)
    }

    func startEndpoint(forEndpointID endpointID: String, port: Int = 9678) {
        endpointsByProfile[endpointID] = .starting(port: port)

        // Preview-only transition for views that seed model state without a server runtime.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.finishStartingEndpoint(forEndpointID: endpointID)
        }
    }

    func stopEndpoint(forProfile name: String) {
        stopEndpoint(forEndpointID: name)
    }

    func stopEndpoint(forEndpointID endpointID: String) {
        serversByProfile[endpointID]?.stop()
        serversByProfile[endpointID] = nil
        runtimeInfoByProfile[endpointID] = nil
        endpointsByProfile[endpointID] = .inactive
        unpublishPortIfNoActiveServers()
    }

    func retryEndpoint(
        for node: ProfileNode,
        credentialsModel: CredentialsModel
    ) async {
        let port = state(forProfile: node.id).port ?? 9678
        await startEndpoint(for: node, credentialsModel: credentialsModel, port: port)
    }

    func retryEndpoint(
        profileName: String,
        endpointID: String? = nil,
        sessionName: String,
        accountId: String,
        roleName: String,
        region: String,
        credentialsModel: CredentialsModel,
        requestRecorder: RequestRecorder? = nil
    ) async {
        let endpointID = endpointID ?? profileName
        let port = state(forEndpointID: endpointID, profileName: profileName).port ?? 9678
        await startEndpoint(
            endpointID: endpointID,
            profileName: profileName,
            sessionName: sessionName,
            accountId: accountId,
            roleName: roleName,
            region: region,
            credentialsModel: credentialsModel,
            port: port,
            requestRecorder: requestRecorder
        )
    }

    func retryEndpoint(forProfile name: String) {
        retryEndpoint(forEndpointID: name)
    }

    func retryEndpoint(forEndpointID endpointID: String) {
        let port = state(forEndpointID: endpointID).port ?? 9678
        startEndpoint(forEndpointID: endpointID, port: port)
    }

    func restartEndpoint(
        for node: ProfileNode,
        credentialsModel: CredentialsModel
    ) async {
        let port = state(forProfile: node.id).port ?? 9678
        stopEndpoint(forProfile: node.id)
        await startEndpoint(for: node, credentialsModel: credentialsModel, port: port)
    }

    func restartEndpoint(forProfile name: String) {
        restartEndpoint(forEndpointID: name)
    }

    func restartEndpoint(forEndpointID endpointID: String) {
        let port = state(forEndpointID: endpointID).port ?? 9678
        startEndpoint(forEndpointID: endpointID, port: port)
    }

    private func finishStartingEndpoint(forEndpointID endpointID: String) {
        guard case .starting(let port) = state(forEndpointID: endpointID) else { return }
        endpointsByProfile[endpointID] = .active(port: port)
    }

    private func stopEndpoints(onPort port: Int, except keptEndpointID: String) {
        for endpointID in Array(serversByProfile.keys) where endpointID != keptEndpointID {
            guard endpointsByProfile[endpointID]?.port == port else { continue }
            stopEndpoint(forEndpointID: endpointID)
        }
        for endpointID in Array(endpointsByProfile.keys) where endpointID != keptEndpointID {
            if case .active(let activePort) = endpointsByProfile[endpointID], activePort == port {
                endpointsByProfile[endpointID] = .inactive
            }
        }
    }

    private func recordRequest(_ log: IMDSRequestLog, forEndpointID endpointID: String) {
        guard var runtime = runtimeInfoByProfile[endpointID] else { return }
        runtime.requestCount += 1
        runtime.activity.insert(log, at: 0)
        if runtime.activity.count > 50 {
            runtime.activity.removeLast(runtime.activity.count - 50)
        }
        runtimeInfoByProfile[endpointID] = runtime
    }

    private func markEndpointFailed(forEndpointID endpointID: String, port: Int, message: String) {
        serversByProfile[endpointID]?.stop()
        serversByProfile[endpointID] = nil
        runtimeInfoByProfile[endpointID] = nil
        endpointsByProfile[endpointID] = .failed(port: port, message: message)
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
        guard serversByProfile.isEmpty else { return }
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
