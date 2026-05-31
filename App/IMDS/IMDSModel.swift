import Foundation
import AWSConfigINI
import IAMIdentityCenter
import Observation

@Observable
@MainActor
final class IMDSModel {
    private(set) var endpointsByProfile: [String: IMDSEndpointState] = [:]
    private(set) var runtimeInfoByProfile: [String: IMDSRuntimeInfo] = [:]
    @ObservationIgnored private var serversByProfile: [String: LocalIMDSServer] = [:]

    func state(forProfile name: String) -> IMDSEndpointState {
        endpointsByProfile[name] ?? .inactive
    }

    func runtimeInfo(forProfile name: String) -> IMDSRuntimeInfo? {
        runtimeInfoByProfile[name]
    }

    func setState(_ state: IMDSEndpointState, forProfile name: String) {
        endpointsByProfile[name] = state
    }

    func startEndpoint(
        for node: ProfileNode,
        credentialsModel: CredentialsModel,
        port: Int = 9678
    ) async {
        guard let sessionName = node.profile.ssoSession,
              let accountId = node.profile.ssoAccountId,
              let roleName = node.profile.ssoRoleName else {
            endpointsByProfile[node.id] = .failed(port: port, message: "Profile is missing SSO account, role, or session metadata.")
            return
        }

        await startEndpoint(
            profileName: node.id,
            sessionName: sessionName,
            accountId: accountId,
            roleName: roleName,
            region: node.profile.region ?? "us-east-1",
            credentialsModel: credentialsModel,
            port: port
        )
    }

    func startEndpoint(
        profileName: String,
        sessionName: String,
        accountId: String,
        roleName: String,
        region: String,
        credentialsModel: CredentialsModel,
        port: Int = 9678
    ) async {
        endpointsByProfile[profileName] = .starting(port: port)

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

            stopAllEndpoints(except: profileName)
            serversByProfile[profileName]?.stop()

            let server = LocalIMDSServer(
                port: port,
                servedProfile: servedProfile,
                onRequest: { [weak self] log in
                    Task { @MainActor in
                        self?.recordRequest(log, forProfile: profileName)
                    }
                },
                onFailure: { [weak self] message in
                    Task { @MainActor in
                        self?.markEndpointFailed(forProfile: profileName, port: port, message: message)
                    }
                }
            )

            serversByProfile[profileName] = server
            runtimeInfoByProfile[profileName] = IMDSRuntimeInfo(servedProfileName: profileName)
            try await server.start()
            let boundPort = server.boundPort
            endpointsByProfile[profileName] = .active(port: boundPort)
            publishPort(boundPort)
        } catch is CancellationError {
            stopEndpoint(forProfile: profileName)
        } catch {
            serversByProfile[profileName]?.stop()
            serversByProfile[profileName] = nil
            runtimeInfoByProfile[profileName] = nil
            endpointsByProfile[profileName] = .failed(port: port, message: displayMessage(for: error))
            unpublishPortIfNoActiveServers()
        }
    }

    func startEndpoint(forProfile name: String, port: Int = 9678) {
        endpointsByProfile[name] = .starting(port: port)

        // Preview-only transition for views that seed model state without a server runtime.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.finishStartingEndpoint(forProfile: name)
        }
    }

    func stopEndpoint(forProfile name: String) {
        serversByProfile[name]?.stop()
        serversByProfile[name] = nil
        runtimeInfoByProfile[name] = nil
        endpointsByProfile[name] = .inactive
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
        sessionName: String,
        accountId: String,
        roleName: String,
        region: String,
        credentialsModel: CredentialsModel
    ) async {
        let port = state(forProfile: profileName).port ?? 9678
        await startEndpoint(
            profileName: profileName,
            sessionName: sessionName,
            accountId: accountId,
            roleName: roleName,
            region: region,
            credentialsModel: credentialsModel,
            port: port
        )
    }

    func retryEndpoint(forProfile name: String) {
        let port = state(forProfile: name).port ?? 9678
        startEndpoint(forProfile: name, port: port)
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
        let port = state(forProfile: name).port ?? 9678
        startEndpoint(forProfile: name, port: port)
    }

    private func finishStartingEndpoint(forProfile name: String) {
        guard case .starting(let port) = state(forProfile: name) else { return }
        endpointsByProfile[name] = .active(port: port)
    }

    private func stopAllEndpoints(except keptProfileName: String) {
        for profileName in Array(serversByProfile.keys) where profileName != keptProfileName {
            stopEndpoint(forProfile: profileName)
        }
        for profileName in Array(endpointsByProfile.keys) where profileName != keptProfileName {
            if case .active = endpointsByProfile[profileName] {
                endpointsByProfile[profileName] = .inactive
            }
        }
    }

    private func recordRequest(_ log: IMDSRequestLog, forProfile name: String) {
        guard var runtime = runtimeInfoByProfile[name] else { return }
        runtime.requestCount += 1
        runtime.activity.insert(log, at: 0)
        if runtime.activity.count > 50 {
            runtime.activity.removeLast(runtime.activity.count - 50)
        }
        runtimeInfoByProfile[name] = runtime
    }

    private func markEndpointFailed(forProfile name: String, port: Int, message: String) {
        serversByProfile[name]?.stop()
        serversByProfile[name] = nil
        runtimeInfoByProfile[name] = nil
        endpointsByProfile[name] = .failed(port: port, message: message)
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
