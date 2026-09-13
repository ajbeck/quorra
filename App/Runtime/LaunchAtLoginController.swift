import Observation
import ServiceManagement

@MainActor
@Observable
final class LaunchAtLoginController {
    private static let loginItemIdentifier = "dev.ajbeck.quorra.login-item"

    enum Status: Equatable {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound
    }

    private(set) var status: Status = .notRegistered
    private(set) var errorMessage: String?

    @ObservationIgnored private let service: SMAppService
    @ObservationIgnored private let legacyService: SMAppService

    init(
        service: SMAppService = .loginItem(identifier: loginItemIdentifier),
        legacyService: SMAppService = .mainApp
    ) {
        self.service = service
        self.legacyService = legacyService
        migrateLegacyRegistrationIfNeeded()
        refresh()
    }

    var isRequested: Bool {
        status == .enabled || status == .requiresApproval
    }

    func setEnabled(_ isEnabled: Bool) {
        errorMessage = nil

        do {
            if isEnabled {
                guard !isRequested else { return }
                try service.register()
            } else {
                if status != .notRegistered {
                    try service.unregister()
                }
                if legacyService.status != .notRegistered {
                    try legacyService.unregister()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        refresh()
    }

    func refresh() {
        switch service.status {
        case .notRegistered:
            status = .notRegistered
        case .enabled:
            status = .enabled
        case .requiresApproval:
            status = .requiresApproval
        case .notFound:
            status = .notFound
        @unknown default:
            status = .notFound
        }

        if status == .enabled, legacyService.status != .notRegistered {
            do {
                try legacyService.unregister()
            } catch {
                errorMessage = "Quorra enabled its login item but could not remove the previous registration. \(error.localizedDescription)"
            }
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func migrateLegacyRegistrationIfNeeded() {
        guard legacyService.status == .enabled
                || legacyService.status == .requiresApproval else { return }

        do {
            if service.status == .notRegistered {
                try service.register()
            }
            if service.status == .enabled {
                try legacyService.unregister()
            }
        } catch {
            errorMessage = "Quorra could not update its launch-at-login registration. \(error.localizedDescription)"
        }
    }
}
