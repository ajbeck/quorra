import Foundation
@preconcurrency import SystemExtensions

enum IMDSSystemExtensionStatus: Equatable {
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

enum IMDSSystemExtensionError: LocalizedError {
    case activationAlreadyInProgress
    case activationFailed(String)
    case restartRequired

    var errorDescription: String? {
        switch self {
        case .activationAlreadyInProgress:
            return "The system metadata endpoint extension is already being activated."
        case .activationFailed(let message):
            return message
        case .restartRequired:
            return "Restart this Mac to finish activating the system metadata endpoint extension."
        }
    }
}

@MainActor
final class IMDSSystemExtensionController: NSObject, OSSystemExtensionRequestDelegate {
    typealias StatusHandler = @MainActor (IMDSSystemExtensionStatus) -> Void

    private let bundleIdentifier: String
    private let statusHandler: StatusHandler
    private var activeRequest: OSSystemExtensionRequest?
    private var activationContinuation: CheckedContinuation<OSSystemExtensionRequest.Result, Error>?
    private var status: IMDSSystemExtensionStatus = .notRequested

    init(bundleIdentifier: String, statusHandler: @escaping StatusHandler) {
        self.bundleIdentifier = bundleIdentifier
        self.statusHandler = statusHandler
        super.init()
    }

    func activate() async throws {
        switch status {
        case .activated:
            return
        case .restartRequired:
            throw IMDSSystemExtensionError.restartRequired
        case .notRequested, .activating, .awaitingApproval, .failed:
            break
        }

        guard activationContinuation == nil else {
            throw IMDSSystemExtensionError.activationAlreadyInProgress
        }

        updateStatus(.activating)
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: bundleIdentifier,
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
                updateStatus(.activated)
            case .willCompleteAfterReboot:
                updateStatus(.restartRequired)
                throw IMDSSystemExtensionError.restartRequired
            @unknown default:
                updateStatus(.restartRequired)
                throw IMDSSystemExtensionError.restartRequired
            }
        } catch {
            activeRequest = nil
            if case IMDSSystemExtensionError.restartRequired = error {
                throw error
            }
            let message = Self.actionableMessage(for: error)
            updateStatus(.failed(message))
            throw IMDSSystemExtensionError.activationFailed(message)
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
        updateStatus(.awaitingApproval)
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

    private func updateStatus(_ status: IMDSSystemExtensionStatus) {
        self.status = status
        statusHandler(status)
    }

    private static func actionableMessage(for error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == OSSystemExtensionErrorDomain,
              let code = OSSystemExtensionError.Code(rawValue: nsError.code) else {
            return error.localizedDescription
        }

        switch code {
        case .unsupportedParentBundleLocation:
            return "Move Quorra to Applications, reopen it, and enable the default EC2 metadata URL again."
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
