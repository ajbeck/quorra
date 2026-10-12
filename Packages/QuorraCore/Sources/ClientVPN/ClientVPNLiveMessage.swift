import Foundation

/// Size limits shared by the app, the wire format and the packet tunnel.
public enum ClientVPNLimits {
    /// The largest `.ovpn` profile, in UTF-8 bytes.
    public static let profileBytes = 64 * 1_024
    /// AWS Client VPN's budget for one sign-in: the SAML assertion plus the challenge cookie, or a cached token.
    public static let credentialBytes = 120 * 1_024
    public static let tokenUsernameBytes = 4_096
    public static let challengeCookieBytes = 8_192
    /// Entries in each list of the tunnel's settings. Sized so the fullest settings and the largest
    /// token still fit in one message.
    public static let tunnelEntries = 32
    /// One address, route or DNS server in CIDR or plain text; an IPv6 CIDR is at most 43 bytes.
    public static let tunnelEntryBytes = 64
    /// One message between the app and the packet tunnel, header included.
    public static let messageBytes = 128 * 1_024
}

public enum ClientVPNLiveFailure: Int, Error, Sendable, LocalizedError, CustomNSError {
    case invalidProfile = 1, invalidCredentials, busy, authentication, transport
    case networkSettings, cancelled, packetOverflow, staleRequest, timedOut, callbackUnavailable
    case notStartedByQuorra, coreUnavailable

    public static var errorDomain: String { "dev.ajbeck.quorra.vpn.live" }
    public var errorCode: Int { rawValue }
    // Carried explicitly so the message survives the trip from the extension to the app.
    public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: message] }
    public var errorDescription: String? { message }

    /// Recovers the failure from an error the system relayed from the packet tunnel.
    public init?(providerError: any Error) {
        let error = providerError as NSError
        guard error.domain == Self.errorDomain else { return nil }
        self.init(rawValue: error.code)
    }

    private var message: String {
        switch self {
        case .invalidProfile: "The VPN profile is unsupported. Check the imported profile and endpoint hostname."
        case .invalidCredentials: "Quorra couldn't use the VPN sign-in response. Connect again to sign in."
        case .busy: "A VPN operation is already running. Disconnect before starting another."
        case .authentication: "The VPN server didn't accept the sign-in. Connect again to sign in."
        case .transport: "The VPN transport ended. Check the network and connect again."
        case .networkSettings: "The VPN network settings could not be applied safely."
        case .cancelled: "The VPN connection was cancelled."
        case .packetOverflow: "The VPN packet path stopped. Connect again to retry."
        case .staleRequest: "This VPN request belongs to an earlier connection attempt."
        case .timedOut: "The VPN didn't connect in time. Connect again to retry."
        case .callbackUnavailable: "The local VPN sign-in callback is unavailable. Quit other VPN sign-in attempts and retry."
        case .notStartedByQuorra: "Connect this VPN from Quorra."
        case .coreUnavailable: "Quorra's VPN component is damaged. Reinstall Quorra."
        }
    }
}

public enum ClientVPNLivePhase: UInt8, Sendable {
    case stopped = 1, awaitingProfile, connecting, authenticating, running, stopping, failed
}

public struct ClientVPNLiveToken: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let username: Data
    public let token: Data
    public var description: String { "VPN session token (redacted)" }
    public var debugDescription: String { description }

    public init(username: Data, token: Data) {
        self.username = username
        self.token = token
    }

    /// Whether the token fits the limits the wire format enforces.
    var isWithinLimits: Bool {
        !username.isEmpty && !token.isEmpty && username.count <= ClientVPNLimits.tokenUsernameBytes
            && username.count + token.count <= ClientVPNLimits.credentialBytes
    }
}

public struct ClientVPNBrowserChallenge: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let url: URL
    public var description: String { "VPN browser challenge (redacted)" }
    public var debugDescription: String { description }

    public init(id: UUID, url: URL) {
        self.id = id
        self.url = url
    }
}

public struct ClientVPNPacketCounts: Equatable, Sendable {
    public var sent: UInt64
    public var received: UInt64

    public init(sent: UInt64 = 0, received: UInt64 = 0) {
        self.sent = sent
        self.received = received
    }
}

/// The network settings the tunnel applied, as text for display.
public struct ClientVPNTunnelSettings: Equatable, Sendable {
    /// Addresses assigned to this Mac, in CIDR form.
    public let addresses: [String]
    /// Destinations sent through the tunnel, in CIDR form. `0.0.0.0/0` or `::/0` sends all traffic.
    public let routes: [String]
    /// Routes past the first `ClientVPNLimits.tunnelEntries`, counted but not sent to the app.
    public let omittedRoutes: Int
    public let dnsServers: [String]

    /// Keeps the first `ClientVPNLimits.tunnelEntries` of each list, skipping entries too long to be an address.
    public init(addresses: [String], routes: [String], dnsServers: [String]) {
        let routes = routes.filter(Self.fits)
        self.addresses = Array(addresses.filter(Self.fits).prefix(ClientVPNLimits.tunnelEntries))
        self.routes = Array(routes.prefix(ClientVPNLimits.tunnelEntries))
        omittedRoutes = routes.count - self.routes.count
        self.dnsServers = Array(dnsServers.filter(Self.fits).prefix(ClientVPNLimits.tunnelEntries))
    }

    /// The decoded form, which the wire format has already bounded.
    init(addresses: [String], routes: [String], omittedRoutes: Int, dnsServers: [String]) {
        self.addresses = addresses
        self.routes = routes
        self.omittedRoutes = omittedRoutes
        self.dnsServers = dnsServers
    }

    static func fits(_ entry: String) -> Bool {
        !entry.isEmpty && entry.utf8.count <= ClientVPNLimits.tunnelEntryBytes
    }

    /// `address/prefix` for an IPv4 address and subnet mask, or nil when the mask isn't contiguous.
    public static func cidr(address: String, subnetMask: String) -> String? {
        let octets = subnetMask.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        let mask = octets.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let prefix = mask.nonzeroBitCount
        guard mask == (prefix == 0 ? 0 : UInt32.max << (32 - prefix)) else { return nil }
        return "\(address)/\(prefix)"
    }
}

public struct ClientVPNLiveSnapshot: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let run: UUID
    public let phase: ClientVPNLivePhase
    public let challenge: ClientVPNBrowserChallenge?
    public let token: ClientVPNLiveToken?
    public let failure: ClientVPNLiveFailure?
    public let packets: ClientVPNPacketCounts
    /// Present only while the tunnel is running.
    public let tunnel: ClientVPNTunnelSettings?
    public var description: String { "VPN status: \(phase)" }
    public var debugDescription: String { description }

    public init(run: UUID, phase: ClientVPNLivePhase, challenge: ClientVPNBrowserChallenge? = nil, token: ClientVPNLiveToken? = nil, failure: ClientVPNLiveFailure? = nil, packets: ClientVPNPacketCounts = .init(), tunnel: ClientVPNTunnelSettings? = nil) {
        self.run = run
        self.phase = phase
        self.challenge = challenge
        self.token = token
        self.failure = failure
        self.packets = packets
        self.tunnel = tunnel
    }
}

public enum ClientVPNLiveRequest: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case connect(run: UUID, profile: String, token: ClientVPNLiveToken?)
    case authenticate(run: UUID, challenge: UUID, assertion: Data)
    case status(run: UUID)
    case stop(run: UUID)

    public var run: UUID {
        switch self {
        case .connect(let id, _, _), .authenticate(let id, _, _), .status(let id), .stop(let id): id
        }
    }
    public var description: String { "VPN request (redacted)" }
    public var debugDescription: String { description }
}

public enum ClientVPNLiveResponse: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case snapshot(ClientVPNLiveSnapshot)
    case rejected(ClientVPNLiveFailure)
    public var description: String { "VPN response (redacted)" }
    public var debugDescription: String { description }
}
