import Foundation
import AWSConfigINI
import IAMIdentityCenter
import Observation
import QuorraAppLogic

@Observable
@MainActor
final class IMDSModel {
    typealias RequestRecorder = @MainActor (_ endpointID: String, _ log: IMDSRequestLog) -> Void

    private(set) var endpointsByEndpointID: [String: IMDSEndpointState] = [:]
    private(set) var runtimeInfoByEndpointID: [String: IMDSRuntimeInfo] = [:]
    @ObservationIgnored private var serversByEndpointID: [String: LocalIMDSServer] = [:]

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
        port: Int = 9678,
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
        endpointsByEndpointID[endpointID] = .starting(port: port)

        do {
            _ = try await credentialsModel.liveCredentials(
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

            let server = LocalIMDSServer(
                port: port,
                servedProfile: servedProfile,
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
            endpointsByEndpointID[endpointID] = .active(port: boundPort)
            publishPort(boundPort)
        } catch is CancellationError {
            stopEndpoint(forEndpointID: endpointID)
        } catch {
            serversByEndpointID[endpointID]?.stop()
            serversByEndpointID[endpointID] = nil
            runtimeInfoByEndpointID[endpointID] = nil
            endpointsByEndpointID[endpointID] = .failed(port: port, message: displayMessage(for: error))
            unpublishPortIfNoActiveServers()
        }
    }

    func stopEndpoint(forEndpointID endpointID: String) {
        serversByEndpointID[endpointID]?.stop()
        serversByEndpointID[endpointID] = nil
        runtimeInfoByEndpointID[endpointID] = nil
        endpointsByEndpointID[endpointID] = .inactive
        unpublishPortIfNoActiveServers()
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

    private func markEndpointFailed(forEndpointID endpointID: String, port: Int, message: String) {
        serversByEndpointID[endpointID]?.stop()
        serversByEndpointID[endpointID] = nil
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
