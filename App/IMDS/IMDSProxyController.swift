import Foundation
import NetworkExtension
import Observation
import QuorraAppLogic

enum IMDSProxyControllerError: LocalizedError {
    case configurationUnavailable

    var errorDescription: String? {
        switch self {
        case .configurationUnavailable:
            return "The system metadata endpoint configuration is unavailable."
        }
    }
}

@MainActor
@Observable
final class IMDSProxyController {
    enum ConnectionStatus: Equatable {
        case notInstalled
        case disconnected
        case connecting
        case connected
        case disconnecting

        var description: String {
            switch self {
            case .notInstalled: return "Not configured"
            case .disconnected: return "Ready"
            case .connecting: return "Connecting"
            case .connected: return "Connected"
            case .disconnecting: return "Disconnecting"
            }
        }
    }

    nonisolated static let providerBundleIdentifier = "dev.ajbeck.quorra.imds-proxy"
    nonisolated static let localizedDescription = "Quorra IMDSv2"

    private(set) var connectionStatus: ConnectionStatus = .notInstalled
    private(set) var errorMessage: String?

    @ObservationIgnored private var manager: NETransparentProxyManager?
    @ObservationIgnored private var statusObserver: NSObjectProtocol?

    init() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshConnectionStatus()
            }
        }
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    var isInstalled: Bool {
        manager != nil
    }

    func refresh() async {
        do {
            manager = try await loadConfiguredManager()
            refreshConnectionStatus()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setInstalled(_ shouldInstall: Bool) async {
        errorMessage = nil
        do {
            if shouldInstall {
                _ = try await installConfiguration()
            } else {
                try await removeConfiguration()
            }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func start() async throws {
        errorMessage = nil
        do {
            let manager = try await installConfiguration()
            switch manager.connection.status {
            case .connected, .connecting, .reasserting:
                refreshConnectionStatus()
                return
            case .invalid, .disconnected, .disconnecting:
                try manager.connection.startVPNTunnel()
                connectionStatus = .connecting
            @unknown default:
                try manager.connection.startVPNTunnel()
                connectionStatus = .connecting
            }
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func stop() {
        guard let manager else {
            connectionStatus = .notInstalled
            return
        }
        manager.connection.stopVPNTunnel()
        refreshConnectionStatus()
    }

    private func installConfiguration() async throws -> NETransparentProxyManager {
        let manager = try await loadConfiguredManager() ?? NETransparentProxyManager()
        let providerProtocol = NETunnelProviderProtocol()
        providerProtocol.providerBundleIdentifier = Self.providerBundleIdentifier
        providerProtocol.serverAddress = DefaultIMDSEndpoint.bindAddress

        manager.localizedDescription = Self.localizedDescription
        manager.protocolConfiguration = providerProtocol
        manager.isEnabled = true

        try await save(manager)
        try await reload(manager)
        self.manager = manager
        refreshConnectionStatus()
        return manager
    }

    private func removeConfiguration() async throws {
        guard let manager = try await loadConfiguredManager() else {
            self.manager = nil
            connectionStatus = .notInstalled
            return
        }
        manager.connection.stopVPNTunnel()
        try await remove(manager)
        self.manager = nil
        connectionStatus = .notInstalled
    }

    private func loadConfiguredManager() async throws -> NETransparentProxyManager? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NETransparentProxyManager?, Error>) in
            NETransparentProxyManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let matchingManager = managers?.first { manager in
                    guard let configuration = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                        return false
                    }
                    return configuration.providerBundleIdentifier == Self.providerBundleIdentifier
                }
                continuation.resume(returning: matchingManager)
            }
        }
    }

    private func save(_ manager: NETransparentProxyManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func reload(_ manager: NETransparentProxyManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func remove(_ manager: NETransparentProxyManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.removeFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func refreshConnectionStatus() {
        guard let manager else {
            connectionStatus = .notInstalled
            return
        }
        switch manager.connection.status {
        case .invalid, .disconnected:
            connectionStatus = .disconnected
        case .connecting, .reasserting:
            connectionStatus = .connecting
        case .connected:
            connectionStatus = .connected
        case .disconnecting:
            connectionStatus = .disconnecting
        @unknown default:
            connectionStatus = .disconnected
        }
    }
}
