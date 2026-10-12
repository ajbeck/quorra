import ClientVPN
import Foundation
import NetworkExtension
import OSLog
import QuorraOpenVPN

private let logger = Logger(subsystem: "dev.ajbeck.quorra", category: "ClientVPN.PacketTunnel")

/// Quorra's AWS Client VPN tunnel. The app starts it with a run ID, then drives the run with
/// provider messages: the profile, the browser sign-in result, status and stop.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    // Unchecked because NEPacketTunnelProvider isn't Sendable. This class adds no mutable state;
    // the session actor owns the run.
    private let session = ClientVPNLiveSession()

    override init() {
        super.init()
        Task { [session] in
            for await activity in session.activity {
                switch activity {
                case .phase(let phase): logger.notice("Phase: \(String(describing: phase), privacy: .public)")
                case .tokenIssued: logger.notice("Session token issued")
                }
            }
        }
    }

    override func startTunnel(options: [String: NSObject]?) async throws {
        guard let value = options?[ClientVPNWire.startOption] as? String, let run = UUID(uuidString: value) else {
            logger.error("Start refused: no run ID, so Quorra didn't start this tunnel")
            throw ClientVPNLiveFailure.notStartedByQuorra
        }
        guard VPNCore.selfTest() else {
            logger.fault("Start refused: the OpenVPN core failed its self-test")
            throw ClientVPNLiveFailure.coreUnavailable
        }
        do {
            try await session.start(
                run: run,
                makeEngine: { [weak self] events in self.map { NativeClientVPNEngine(provider: $0, events: events) } },
                cancelTunnel: { [weak self] failure in
                    logger.error("Tunnel ended: \(failure.rawValue, privacy: .public)")
                    self?.cancelTunnelWithError(failure)
                }
            )
        } catch {
            logger.error("Start failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        logger.notice("Stop requested by the system: \(reason.rawValue, privacy: .public)")
        await session.stop()
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        do {
            let request = try ClientVPNWire.decodeRequest(messageData)
            return try ClientVPNWire.encode(await session.handle(request))
        } catch {
            logger.error("App message failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
