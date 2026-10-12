import ClientVPN
import Foundation

/// The tunnel's status as the system reports it.
public enum ClientVPNTunnelStatus: Equatable, Sendable {
    case disconnected, connecting, connected, disconnecting
}

/// The system side of a Client VPN connection: the app's NetworkExtension transport, or a fake in tests.
@MainActor
public protocol ClientVPNTransport: AnyObject, Sendable {
    var status: ClientVPNTunnelStatus { get }
    /// The tunnel's status each time the system reports a change, until the caller stops listening.
    func statusChanges() -> AsyncStream<ClientVPNTunnelStatus>
    /// Prepares the extension and configuration, then starts the tunnel for `run`.
    func start(run: UUID) async throws
    func send(_ request: ClientVPNLiveRequest) async throws -> ClientVPNLiveResponse
    /// Stops the tunnel and returns once the system reports it disconnected.
    func stop() async
    /// Why the tunnel last stopped, as the provider reported it.
    func lastFailure() async -> ClientVPNLiveFailure?
}
