import Foundation
import Observation
@preconcurrency import SystemExtensions

enum SystemExtensionStatus: Equatable {
    case notRequested
    case activating
    case awaitingApproval
    case activated
    case restartRequired
    case failed(String)

    var description: String {
        switch self {
        case .notRequested:
            return "Not checked"
        case .activating:
            return "Installing"
        case .awaitingApproval:
            return "Approval required"
        case .activated:
            return "Installed"
        case .restartRequired:
            return "Restart required"
        case .failed:
            return "Installation failed"
        }
    }
}

enum SystemExtensionError: LocalizedError {
    case activationAlreadyInProgress
    case activationFailed(String)
    case restartRequired

    var errorDescription: String? {
        switch self {
        case .activationAlreadyInProgress:
            return "Quorra’s system extension is already being activated."
        case .activationFailed(let message):
            return message
        case .restartRequired:
            return "Restart this Mac to finish activating Quorra’s system extension."
        }
    }
}

/// Activates Quorra's one system extension, which hosts both the IMDS proxy and the Client VPN
/// tunnel. The app keeps a single instance so the two features never submit competing requests.
@MainActor
@Observable
final class SystemExtensionController: NSObject, OSSystemExtensionRequestDelegate {
    nonisolated static let bundleIdentifier = "dev.ajbeck.quorra.imds-proxy"

    private(set) var status: SystemExtensionStatus = .notRequested
    @ObservationIgnored private var activeRequest: OSSystemExtensionRequest?
    @ObservationIgnored private var activationContinuation: CheckedContinuation<OSSystemExtensionRequest.Result, Error>?

    func activate() async throws {
        switch status {
        case .activated:
            return
        case .restartRequired:
            throw SystemExtensionError.restartRequired
        case .notRequested, .activating, .awaitingApproval, .failed:
            break
        }

        guard activationContinuation == nil else {
            throw SystemExtensionError.activationAlreadyInProgress
        }

        status = .activating
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.bundleIdentifier,
            queue: .main
        )
        request.delegate = self
        activeRequest = request

        do {
            let result = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<OSSystemExtensionRequest.Result, Error>) in
                activationContinuation = continuation
                OSSystemExtensionManager.shared.submitRequest(request)
            }
            activeRequest = nil

            switch result {
            case .completed:
                status = .activated
            case .willCompleteAfterReboot:
                status = .restartRequired
                throw SystemExtensionError.restartRequired
            @unknown default:
                status = .restartRequired
                throw SystemExtensionError.restartRequired
            }
        } catch {
            activeRequest = nil
            if case SystemExtensionError.restartRequired = error {
                throw error
            }
            let message = Self.actionableMessage(for: error)
            status = .failed(message)
            throw SystemExtensionError.activationFailed(message)
        }
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension candidate: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        let comparison = existing.bundleVersion.compare(
            candidate.bundleVersion,
            options: .numeric
        )
        return comparison == .orderedDescending ? .cancel : .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        status = .awaitingApproval
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        finishRequest(request, with: .success(result))
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        finishRequest(request, with: .failure(error))
    }

    private func finishRequest(
        _ request: OSSystemExtensionRequest,
        with result: Result<OSSystemExtensionRequest.Result, Error>
    ) {
        guard request === activeRequest else { return }
        let continuation = activationContinuation
        activationContinuation = nil
        continuation?.resume(with: result)
    }

    private static func actionableMessage(for error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == OSSystemExtensionErrorDomain,
              let code = OSSystemExtensionError.Code(rawValue: nsError.code) else {
            return error.localizedDescription
        }

        switch code {
        case .unsupportedParentBundleLocation:
            return "Move Quorra to Applications, reopen it, and try again."
        case .missingEntitlement, .codeSignatureInvalid, .validationFailed:
            return "This Quorra build is not signed correctly for its system extension."
        case .forbiddenBySystemPolicy, .authorizationRequired:
            return "Enable Quorra’s Network Extension in System Settings under General → Login Items & Extensions, then try again."
        case .requestCanceled:
            return "System extension activation was canceled."
        default:
            return error.localizedDescription
        }
    }
}
