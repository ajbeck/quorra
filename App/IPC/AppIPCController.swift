import AppKit
import Foundation
import OSLog
import QuorraAppLogic
import SwiftData

private let appIPCLogger = Logger(subsystem: "dev.ajbeck.quorra", category: "IPC")

@MainActor
final class AppIPCController {
    private let server: QuorraIPCServer

    init(
        runtimeCoordinator: AppRuntimeCoordinator,
        profilesModel: ProfilesModel,
        credentialsModel: CredentialsModel,
        imdsModel: IMDSModel,
        modelContext: ModelContext,
        bundle: Bundle = .main
    ) {
        let appVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let requestHandler = AppIPCRequestHandler(
            appVersion: appVersion,
            runtimeCoordinator: runtimeCoordinator,
            profileSignInCoordinator: ProfileSignInOperationCoordinator(
                profilesModel: profilesModel,
                credentialsModel: credentialsModel
            ),
            imdsModel: imdsModel,
            modelContext: modelContext
        )

        server = QuorraIPCServer { request in
            await requestHandler.handle(request)
        }
    }

    func start() {
        do {
            try server.start()
        } catch {
            appIPCLogger.error("Unable to start CLI service: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        server.stop()
    }
}

@MainActor
private final class AppIPCRequestHandler {
    private let appVersion: String
    private let runtimeCoordinator: AppRuntimeCoordinator
    private let profileSignInCoordinator: ProfileSignInOperationCoordinator
    private let imdsModel: IMDSModel
    private let modelContext: ModelContext

    init(
        appVersion: String,
        runtimeCoordinator: AppRuntimeCoordinator,
        profileSignInCoordinator: ProfileSignInOperationCoordinator,
        imdsModel: IMDSModel,
        modelContext: ModelContext
    ) {
        self.appVersion = appVersion
        self.runtimeCoordinator = runtimeCoordinator
        self.profileSignInCoordinator = profileSignInCoordinator
        self.imdsModel = imdsModel
        self.modelContext = modelContext
    }

    func handle(_ request: QuorraIPCRequest) async -> QuorraIPCResponse {
        do {
            switch request.operation {
            case .handshake:
                return try .success(
                    requestID: request.requestID,
                    payload: QuorraIPCServerInfo(appVersion: appVersion)
                )
            case .appTerminate:
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    NSApplication.shared.terminate(nil)
                }
                return try .success(
                    requestID: request.requestID,
                    payload: QuorraIPCAcknowledgement()
                )
            case .profileSignInStart:
                guard let profileName = request.arguments["profile"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !profileName.isEmpty else {
                    throw AppIPCHandlerError(
                        code: .invalidRequest,
                        message: "A profile name is required."
                    )
                }
                return try .success(
                    requestID: request.requestID,
                    payload: profileSignInCoordinator.begin(profileName: profileName)
                )
            case .profileSignInStatus:
                return try .success(
                    requestID: request.requestID,
                    payload: try profileSignInCoordinator.operation(
                        id: try resolveOperationID(from: request)
                    )
                )
            case .profileSignInCancel:
                return try .success(
                    requestID: request.requestID,
                    payload: try await profileSignInCoordinator.cancel(
                        id: try resolveOperationID(from: request)
                    )
                )
            case .imdsList:
                return try .success(
                    requestID: request.requestID,
                    payload: try endpointDefinitions().map(endpointRecord)
                )
            case .imdsStatus:
                let definition = try resolveEndpoint(from: request)
                return try .success(
                    requestID: request.requestID,
                    payload: endpointRecord(definition)
                )
            case .imdsStart:
                let definition = try resolveEndpoint(from: request)
                try await runtimeCoordinator.startEndpoint(definition)
                return try .success(
                    requestID: request.requestID,
                    payload: endpointRecord(definition)
                )
            case .imdsStop:
                let definition = try resolveEndpoint(from: request)
                await runtimeCoordinator.stopEndpoint(definition)
                return try .success(
                    requestID: request.requestID,
                    payload: endpointRecord(definition)
                )
            case .imdsSwitchProfile:
                let definition = try resolveEndpoint(from: request)
                guard DefaultIMDSEndpoint.matches(definition) else {
                    throw AppIPCHandlerError(
                        code: .invalidRequest,
                        message: "Only the Default IMDS Endpoint can switch profiles."
                    )
                }
                guard let profileName = request.arguments["profile"], !profileName.isEmpty else {
                    throw AppIPCHandlerError(
                        code: .invalidRequest,
                        message: "A profile name is required."
                    )
                }
                try await runtimeCoordinator.switchDefaultEndpointProfile(to: profileName)
                return try .success(
                    requestID: request.requestID,
                    payload: endpointRecord(definition)
                )
            }
        } catch let error as AppIPCHandlerError {
            return .failure(
                requestID: request.requestID,
                code: error.code,
                message: error.message
            )
        } catch AppRuntimeOperationError.profilesNotReady {
            return .failure(
                requestID: request.requestID,
                code: .notReady,
                message: AppRuntimeOperationError.profilesNotReady.localizedDescription
            )
        } catch ProfileSignInOperationError.profilesNotReady {
            return .failure(
                requestID: request.requestID,
                code: .notReady,
                message: ProfileSignInOperationError.profilesNotReady.localizedDescription
            )
        } catch let error as ProfileSignInOperationError {
            let code: QuorraIPCErrorCode
            switch error {
            case .profileNotFound, .operationNotFound:
                code = .notFound
            case .profileDoesNotUseIdentityCenter, .sessionNotFound, .invalidSession:
                code = .invalidRequest
            case .profilesNotReady:
                code = .notReady
            }
            return .failure(
                requestID: request.requestID,
                code: code,
                message: error.localizedDescription
            )
        } catch {
            return .failure(
                requestID: request.requestID,
                code: .operationFailed,
                message: error.localizedDescription
            )
        }
    }

    private func endpointDefinitions() throws -> [IMDSEndpointDefinition] {
        try modelContext.fetch(FetchDescriptor<IMDSEndpointDefinition>())
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func resolveOperationID(from request: QuorraIPCRequest) throws -> UUID {
        guard let value = request.arguments["operation"],
              let id = UUID(uuidString: value) else {
            throw AppIPCHandlerError(
                code: .invalidRequest,
                message: "A valid sign-in operation identifier is required."
            )
        }
        return id
    }

    private func resolveEndpoint(from request: QuorraIPCRequest) throws -> IMDSEndpointDefinition {
        guard let selector = request.arguments["endpoint"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !selector.isEmpty else {
            throw AppIPCHandlerError(code: .invalidRequest, message: "An endpoint is required.")
        }

        let definitions = try endpointDefinitions()
        if selector.caseInsensitiveCompare("default") == .orderedSame,
           let definition = definitions.first(where: DefaultIMDSEndpoint.matches) {
            return definition
        }
        if let definition = definitions.first(where: {
            $0.stableIDString.caseInsensitiveCompare(selector) == .orderedSame
        }) {
            return definition
        }

        let namedMatches = definitions.filter {
            $0.name.caseInsensitiveCompare(selector) == .orderedSame
        }
        guard let definition = namedMatches.first else {
            throw AppIPCHandlerError(
                code: .notFound,
                message: "No IMDS endpoint matches ‘\(selector)’."
            )
        }
        guard namedMatches.count == 1 else {
            throw AppIPCHandlerError(
                code: .invalidRequest,
                message: "More than one endpoint is named ‘\(selector)’. Use its UUID instead."
            )
        }
        return definition
    }

    private func endpointRecord(_ definition: IMDSEndpointDefinition) -> QuorraIMDSEndpointRecord {
        let state = imdsModel.state(forEndpointID: definition.stableIDString)
        let runtime = imdsModel.runtimeInfo(forEndpointID: definition.stableIDString)
        let status: QuorraIMDSEndpointStatus
        switch state {
        case .inactive:
            status = .inactive
        case .starting:
            status = .starting
        case .active:
            status = .running
        case .failed:
            status = .failed
        }

        return QuorraIMDSEndpointRecord(
            id: definition.stableIDString,
            name: definition.name,
            profileName: definition.profileName.isEmpty ? nil : definition.profileName,
            servedProfileName: runtime?.servedProfileName,
            bindAddress: definition.bindAddress,
            configuredPort: definition.port,
            boundPort: state.isActive
                ? (DefaultIMDSEndpoint.matches(definition) ? definition.port : state.port)
                : nil,
            status: status,
            failureMessage: state.failureMessage,
            isDefault: DefaultIMDSEndpoint.matches(definition)
        )
    }
}

private struct AppIPCHandlerError: Error {
    let code: QuorraIPCErrorCode
    let message: String
}
