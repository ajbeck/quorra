import ClientVPN
import Foundation
@preconcurrency import NetworkExtension
import OSLog
import QuorraOpenVPN
import Synchronization

private let logger = Logger(subsystem: "dev.ajbeck.quorra", category: "ClientVPN.Engine")

/// One OpenVPN attempt on the provider's packet flow, reporting to the live session.
final class NativeClientVPNEngine: ClientVPNLiveEngine {
    private let io: CountingPacketIO
    private let connection: VPNConnection
    private let events: @Sendable (ClientVPNEngineEvent) -> Void

    init(provider: NEPacketTunnelProvider, events: @escaping @Sendable (ClientVPNEngineEvent) -> Void) {
        let io = CountingPacketIO(provider: provider)
        self.io = io
        self.events = events
        connection = VPNConnection(io: io) { event in
            switch event {
            case .connected: events(.connected)
            case .authenticationRequired(let challenge): events(.challenge(url: challenge.url, cookie: challenge.cookie))
            case .token(let token): events(.token(ClientVPNLiveToken(username: token.username, token: token.token)))
            case .stopped(let failure): events(.stopped(failure.map(ClientVPNLiveFailure.init)))
            }
        }
    }

    func start(profile: String, credentials: ClientVPNEngineCredentials?) {
        let native: VPNCredentials?
        do {
            switch credentials {
            case .assertion(let cookie, let response):
                guard let challenge = VPNCore.authenticationChallenge(cookie) else { throw VPNFailure.invalidCredentials }
                native = try VPNCredentials(challenge: challenge, response: response)
            case .token(let token):
                native = try VPNCredentials(username: token.username, token: token.token)
            case nil:
                native = nil
            }
        } catch {
            events(.stopped(.invalidCredentials))
            return
        }
        connection.start(profile: profile, credentials: native)
    }

    func stop() { connection.stop() }
    func packetCounts() -> ClientVPNPacketCounts { io.counts.withLock { $0 } }
    func tunnelSettings() -> ClientVPNTunnelSettings? { io.tunnel.withLock { $0 } }
}

private extension ClientVPNTunnelSettings {
    init(_ settings: NEPacketTunnelNetworkSettings) {
        var addresses: [String] = []
        var routes: [String] = []
        if let ipv4 = settings.ipv4Settings {
            addresses += zip(ipv4.addresses, ipv4.subnetMasks).compactMap { Self.cidr(address: $0, subnetMask: $1) }
            routes += (ipv4.includedRoutes ?? []).compactMap { Self.cidr(address: $0.destinationAddress, subnetMask: $0.destinationSubnetMask) }
        }
        if let ipv6 = settings.ipv6Settings {
            addresses += zip(ipv6.addresses, ipv6.networkPrefixLengths).map { "\($0)/\($1)" }
            routes += (ipv6.includedRoutes ?? []).map { "\($0.destinationAddress)/\($0.destinationNetworkPrefixLength)" }
        }
        self.init(addresses: addresses, routes: routes, dnsServers: settings.dnsSettings?.servers ?? [])
    }
}

private extension ClientVPNLiveFailure {
    // Exhaustive, so a new core failure can't silently become `.transport`.
    init(_ failure: VPNFailure) {
        self = switch failure {
        case .invalidProfile: .invalidProfile
        case .invalidCredentials: .invalidCredentials
        case .busy: .busy
        case .authentication: .authentication
        case .transport: .transport
        case .networkSettings: .networkSettings
        case .cancelled: .cancelled
        case .packetOverflow: .packetOverflow
        }
    }
}

/// The provider's packet flow, counting packets each way and keeping the applied settings for the app's status display.
private final class CountingPacketIO: VPNPacketIO {
    let counts = Mutex(ClientVPNPacketCounts())
    let tunnel = Mutex<ClientVPNTunnelSettings?>(nil)
    private let io: VPNPacketTunnelIO

    init(provider: NEPacketTunnelProvider) {
        io = VPNPacketTunnelIO(provider: provider)
    }

    func apply(_ settings: NEPacketTunnelNetworkSettings?, completion: @escaping @Sendable (Bool) -> Void) {
        let installing = settings != nil
        let display = settings.map(ClientVPNTunnelSettings.init)
        logger.notice("Network settings requested (installing: \(installing))")
        io.apply(settings) { [self] success in
            logger.notice("Network settings applied (installing: \(installing), success: \(success))")
            if success { tunnel.withLock { $0 = display } }
            completion(success)
        }
    }

    func read(completion: @escaping @Sendable (Result<VPNPacketBatch, VPNFailure>) -> Void) {
        io.read { [self] result in
            if case .success(let batch) = result { counts.withLock { $0.sent += UInt64(batch.packets.count) } }
            completion(result)
        }
    }

    func write(_ packet: Data, family: Int32) -> Bool {
        let written = io.write(packet, family: family)
        if written { counts.withLock { $0.received += 1 } }
        return written
    }
}
