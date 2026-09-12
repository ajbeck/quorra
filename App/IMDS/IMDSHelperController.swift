import Foundation
import Observation
import QuorraAppLogic
import ServiceManagement

@MainActor
protocol IMDSHelperRegistrationServicing: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: IMDSHelperRegistrationServicing {}

protocol IMDSHelperRequesting: Sendable {
    func status() async throws -> QuorraIMDSHelperStatus
    func enable() async throws -> QuorraIMDSHelperStatus
    func disable() async throws -> QuorraIMDSHelperStatus
}

extension QuorraIMDSHelperClient: IMDSHelperRequesting {}

enum IMDSHelperControllerError: LocalizedError, Equatable {
    case requiresApproval
    case notAvailable
    case unexpectedState(QuorraIMDSHelperState, String?)

    var errorDescription: String? {
        switch self {
        case .requiresApproval:
            return "Allow Quorra's metadata endpoint helper in Login Items settings, then try again."
        case .notAvailable:
            return "The metadata endpoint helper is unavailable in this build."
        case .unexpectedState(let state, let message):
            return message ?? "The metadata endpoint helper stopped in the \(state.rawValue) state."
        }
    }
}

@MainActor
@Observable
final class IMDSHelperController {
    enum RegistrationStatus: Equatable {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound
    }

    static let daemonPlistName = "dev.ajbeck.quorra.imds-helper.plist"

    private(set) var registrationStatus: RegistrationStatus = .notRegistered
    private(set) var helperStatus: QuorraIMDSHelperStatus?
    private(set) var errorMessage: String?

    @ObservationIgnored private let registrationService: any IMDSHelperRegistrationServicing
    @ObservationIgnored private let helperClient: any IMDSHelperRequesting

    convenience init() {
        self.init(
            registrationService: SMAppService.daemon(plistName: Self.daemonPlistName),
            helperClient: QuorraIMDSHelperClient()
        )
    }

    init(
        registrationService: any IMDSHelperRegistrationServicing,
        helperClient: any IMDSHelperRequesting
    ) {
        self.registrationService = registrationService
        self.helperClient = helperClient
        refreshRegistrationStatus()
    }

    var isRequested: Bool {
        registrationStatus == .enabled || registrationStatus == .requiresApproval
    }

    func refresh() async {
        refreshRegistrationStatus()
        guard registrationStatus == .enabled else {
            helperStatus = nil
            return
        }
        do {
            helperStatus = try await helperClient.status()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setRegistered(_ shouldRegister: Bool) async {
        errorMessage = nil
        do {
            if shouldRegister {
                try registerIfNeeded()
                if registrationStatus == .enabled {
                    helperStatus = try await helperClient.status()
                }
            } else {
                try await unregisterIfNeeded()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshRegistrationStatus()
    }

    @discardableResult
    func enable() async throws -> QuorraIMDSHelperStatus {
        errorMessage = nil
        do {
            try registerIfNeeded()
            try requireEnabledRegistration()
            let status = try await helperClient.enable()
            helperStatus = status
            guard status.state == .enabled else {
                throw IMDSHelperControllerError.unexpectedState(
                    status.state,
                    status.failureMessage
                )
            }
            return status
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    func disable() async throws -> QuorraIMDSHelperStatus? {
        errorMessage = nil
        refreshRegistrationStatus()
        guard registrationStatus == .enabled else {
            helperStatus = nil
            return nil
        }

        do {
            let status = try await helperClient.disable()
            helperStatus = status
            guard status.state == .disabled else {
                throw IMDSHelperControllerError.unexpectedState(
                    status.state,
                    status.failureMessage
                )
            }
            return status
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func registerIfNeeded() throws {
        refreshRegistrationStatus()
        if registrationStatus == .notRegistered {
            do {
                try registrationService.register()
            } catch {
                refreshRegistrationStatus()
                if registrationStatus != .requiresApproval {
                    throw error
                }
            }
            refreshRegistrationStatus()
        }
    }

    private func unregisterIfNeeded() async throws {
        refreshRegistrationStatus()
        if registrationStatus == .enabled {
            _ = try await disable()
        }
        if registrationStatus != .notRegistered {
            try registrationService.unregister()
            helperStatus = nil
        }
    }

    private func requireEnabledRegistration() throws {
        switch registrationStatus {
        case .enabled:
            return
        case .requiresApproval, .notRegistered:
            throw IMDSHelperControllerError.requiresApproval
        case .notFound:
            throw IMDSHelperControllerError.notAvailable
        }
    }

    private func refreshRegistrationStatus() {
        switch registrationService.status {
        case .notRegistered:
            registrationStatus = .notRegistered
        case .enabled:
            registrationStatus = .enabled
        case .requiresApproval:
            registrationStatus = .requiresApproval
        case .notFound:
            registrationStatus = .notFound
        @unknown default:
            registrationStatus = .notFound
        }
    }
}
