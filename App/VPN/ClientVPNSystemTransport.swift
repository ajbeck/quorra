import ClientVPN
import Foundation
import NetworkExtension
import QuorraAppLogic

/// The Client VPN's system side: one "Quorra Client VPN" configuration for the packet tunnel in
/// Quorra's system extension. Each connection's profile travels in its provider messages.
@MainActor
final class ClientVPNSystemTransport: ClientVPNTransport {
    nonisolated static let configurationName = "Quorra Client VPN"

    private let systemExtension: SystemExtensionController
    private var manager: NETunnelProviderManager?

    init(systemExtension: SystemExtensionController) {
        self.systemExtension = systemExtension
    }

    var status: ClientVPNTunnelStatus {
        switch manager?.connection.status {
        case .connecting, .reasserting: .connecting
        case .connected: .connected
        case .disconnecting: .disconnecting
        case .invalid, .disconnected, nil: .disconnected
        @unknown default: .disconnected
        }
    }

    func statusChanges() -> AsyncStream<ClientVPNTunnelStatus> {
        AsyncStream { continuation in
            let observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    continuation.yield(self.status)
                }
            }
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    func start(run: UUID) async throws {
        try await systemExtension.activate()
        let manager = try await installConfiguration()
        // Loading preferences ignores cancellation; don't start a tunnel the user has already disconnected.
        try Task.checkCancellation()
        guard status == .disconnected, let session = manager.connection as? NETunnelProviderSession else {
            throw ClientVPNLiveFailure.busy
        }
        try session.startTunnel(options: [ClientVPNWire.startOption: run.uuidString as NSString])
    }

    func send(_ request: ClientVPNLiveRequest) async throws -> ClientVPNLiveResponse {
        // Messaging a stopped provider can launch a new, unrelated instance of it.
        guard status == .connecting || status == .connected,
              let session = manager?.connection as? NETunnelProviderSession else {
            throw ClientVPNLiveFailure.transport
        }
        let message = try ClientVPNWire.encode(request)
        // The async form of sendProviderMessage drops the reply, so bridge the callback.
        let reply: Data = try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(message) { response in
                    if let response {
                        continuation.resume(returning: response)
                    } else {
                        continuation.resume(throwing: ClientVPNLiveFailure.transport)
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        return try ClientVPNWire.decodeResponse(reply)
    }

    func stop() async {
        guard let manager, status != .disconnected else { return }
        let changes = statusChanges()
        manager.connection.stopVPNTunnel()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for await status in changes where status == .disconnected {
                    return
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(15))
            }
            await group.next()
            group.cancelAll()
        }
    }

    func lastFailure() async -> ClientVPNLiveFailure? {
        guard let connection = manager?.connection else { return nil }
        do {
            try await connection.fetchLastDisconnectError()
            return nil
        } catch {
            return ClientVPNLiveFailure(providerError: error)
        }
    }

    private func installConfiguration() async throws -> NETunnelProviderManager {
        // The IMDS proxy's NETransparentProxyManager shares the provider bundle and is a subclass.
        let existing = try await NETunnelProviderManager.loadAllFromPreferences().first { manager in
            !(manager is NETransparentProxyManager)
                && (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == SystemExtensionController.bundleIdentifier
        }
        if let existing, isCurrent(existing) {
            manager = existing
            return existing
        }
        let manager = existing ?? NETunnelProviderManager()
        let configuration = NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = SystemExtensionController.bundleIdentifier
        configuration.serverAddress = Self.configurationName
        manager.localizedDescription = Self.configurationName
        manager.protocolConfiguration = configuration
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        self.manager = manager
        return manager
    }

    private func isCurrent(_ manager: NETunnelProviderManager) -> Bool {
        guard let configuration = manager.protocolConfiguration as? NETunnelProviderProtocol else { return false }
        return manager.isEnabled
            && manager.localizedDescription == Self.configurationName
            && configuration.serverAddress == Self.configurationName
    }
}
