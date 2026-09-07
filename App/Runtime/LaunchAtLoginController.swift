import Observation
import ServiceManagement

@MainActor
@Observable
final class LaunchAtLoginController {
    enum Status: Equatable {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound
    }

    private(set) var status: Status = .notRegistered
    private(set) var errorMessage: String?

    @ObservationIgnored private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
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
                guard status != .notRegistered else { return }
                try service.unregister()
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
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
