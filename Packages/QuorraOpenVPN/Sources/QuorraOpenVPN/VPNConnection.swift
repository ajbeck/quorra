@preconcurrency import QuorraOpenVPNNative
import Foundation
@preconcurrency import NetworkExtension

public enum VPNFailure: Int, Error, Sendable {
    case invalidProfile = 1, invalidCredentials, busy, authentication, transport
    case networkSettings, cancelled, packetOverflow
}

public struct VPNCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let native: QVPNCredentials

    public init(challenge: VPNAuthenticationChallenge, response: Data) throws {
        guard let value = QVPNCredentials.challenge(challenge.cookie, response: response) else {
            throw VPNFailure.invalidCredentials
        }
        native = value
    }

    public init(username: Data, token: Data) throws {
        guard let value = QVPNCredentials.cachedUsername(username, token: token) else {
            throw VPNFailure.invalidCredentials
        }
        native = value
    }

    public var description: String { "VPN credentials (redacted)" }
    public var debugDescription: String { description }
}

public struct VPNSessionToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let username: Data
    public let token: Data
    public var description: String { "VPN session token (redacted)" }
    public var debugDescription: String { description }
}

public enum VPNEvent: Sendable {
    case connected
    case authenticationRequired(VPNAuthenticationChallenge)
    case token(VPNSessionToken)
    case stopped(VPNFailure?)
}

public struct VPNPacketBatch: Sendable {
    public let packets: [Data]
    public let families: [Int32]
    public init(packets: [Data], families: [Int32]) {
        self.packets = packets
        self.families = families
    }
}

/// System settings and packet-flow operations. Tests substitute an in-memory host.
public protocol VPNPacketIO: Sendable {
    func apply(_ settings: NEPacketTunnelNetworkSettings?, completion: @escaping @Sendable (Bool) -> Void)
    func read(completion: @escaping @Sendable (Result<VPNPacketBatch, VPNFailure>) -> Void)
    func write(_ packet: Data, family: Int32) -> Bool
}

protocol VPNCoreDriving: Sendable {
    func start(profile: String, credentials: QVPNCredentials?) throws
    func stop()
    func send(_ packets: [Data]) -> Bool
}

private struct NativeDriver: VPNCoreDriving {
    let session: QVPNCoreSession
    func start(profile: String, credentials: QVPNCredentials?) throws {
        try session.startProfile(profile, credentials: credentials)
    }
    func stop() { session.stop() }
    func send(_ packets: [Data]) -> Bool { session.sendPackets(packets) }
}

/// Owns one attempt. All mutable state and native callbacks use one serial queue.
/// Terminal delivery waits for the worker and any in-flight settings operation.
public final class VPNConnection: NSObject, QVPNCoreDelegate, @unchecked Sendable {
    enum Phase { case idle, starting, running, stopping, finished }
    typealias DriverFactory = @Sendable (any QVPNCoreDelegate, DispatchQueue) -> any VPNCoreDriving

    private let queue: DispatchQueue
    private let io: any VPNPacketIO
    private let event: @Sendable (VPNEvent) -> Void
    private let factory: DriverFactory
    private var driver: (any VPNCoreDriving)?
    private var phase = Phase.idle
    private var settingsPending: UUID?
    private var settingsInstalled = false
    private var clearStarted = false
    private var workerFinished = false
    private var terminal: VPNEvent?
    private var readPending: UUID?
    private var mtu = 0

    public convenience init(io: any VPNPacketIO, event: @escaping @Sendable (VPNEvent) -> Void) {
        self.init(io: io, queue: DispatchQueue(label: "dev.ajbeck.quorra.vpn.connection"), event: event) { delegate, queue in
            NativeDriver(session: QVPNCoreSession(delegate: delegate, callbackQueue: queue))
        }
    }

    init(io: any VPNPacketIO, queue: DispatchQueue, event: @escaping @Sendable (VPNEvent) -> Void, factory: @escaping DriverFactory) {
        self.io = io
        self.queue = queue
        self.event = event
        self.factory = factory
    }

    public func start(profile: String, credentials: VPNCredentials? = nil) {
        queue.async { [self] in
            guard phase == .idle else { return }
            phase = .starting
            let core = factory(self, queue)
            driver = core
            do { try core.start(profile: profile, credentials: credentials?.native) }
            catch {
                workerFinished = true
                let failure = VPNFailure(rawValue: (error as NSError).code) ?? .transport
                finish(.stopped(failure))
            }
        }
    }

    public func stop() {
        queue.async { [self] in
            guard phase != .finished && phase != .stopping else { return }
            if phase == .idle { workerFinished = true }
            finish(.stopped(.cancelled))
        }
    }

    public func applyVPNSettings(_ settings: NEPacketTunnelNetworkSettings, completion: @escaping (Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard phase == .starting, settingsPending == nil, !settingsInstalled else {
            completion(false)
            return
        }
        let request = UUID()
        settingsPending = request
        mtu = settings.mtu?.intValue ?? 0
        let reply = SettingsReply(completion)
        io.apply(settings) { [self] success in
            queue.async { [self] in
                guard settingsPending == request else { return }
                settingsPending = nil
                // Even a failed operation may have partially changed the interface.
                settingsInstalled = true
                reply.complete(success && phase == .starting)
                if !success && phase == .starting { finish(.stopped(.networkSettings)) }
                completeStopIfPossible()
            }
        }
    }

    public func vpnDidConnect() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard phase == .starting else { return }
        guard settingsInstalled && settingsPending == nil && (1280...1500).contains(mtu) else {
            finish(.stopped(.networkSettings))
            return
        }
        phase = .running
        event(.connected)
        readNext()
    }

    public func writeVPNPacket(_ packet: Data, protocolFamily family: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard phase == .running else { return }
        guard QVPNCore.packetProtocolFamily(packet, maximumTransmissionUnit: UInt(mtu)) == family,
              io.write(packet, family: Int32(family)) else {
            finish(.stopped(.packetOverflow))
            return
        }
    }

    public func vpnRequiresAuthentication(_ challenge: QVPNChallenge) {
        dispatchPrecondition(condition: .onQueue(queue))
        workerFinished = true
        finish(.authenticationRequired(.init(url: challenge.url, cookie: challenge.cookie)))
    }

    public func vpnReceivedToken(_ token: Data, username: Data) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard phase == .running,
              QVPNCredentials.cachedUsername(username, token: token) != nil else { return }
        event(.token(.init(username: username, token: token)))
    }

    public func vpnDidStop(_ failure: QVPNFailure) {
        dispatchPrecondition(condition: .onQueue(queue))
        workerFinished = true
        finish(.stopped(VPNFailure(rawValue: failure.rawValue)))
    }

    private func readNext() {
        guard phase == .running, readPending == nil else { return }
        let request = UUID()
        readPending = request
        io.read { [weak self] result in
            guard let self else { return }
            self.queue.async { [self] in
                guard phase == .running && readPending == request else { return }
                readPending = nil
                let batch: VPNPacketBatch
                switch result {
                case .success(let value): batch = value
                case .failure(let failure):
                    finish(.stopped(failure))
                    return
                }
                let packets = batch.packets, families = batch.families
                guard packets.count == families.count && packets.count <= 1024 else {
                    finish(.stopped(.packetOverflow))
                    return
                }
                for (packet, family) in zip(packets, families) {
                    guard QVPNCore.packetProtocolFamily(packet, maximumTransmissionUnit: UInt(mtu)) == family else {
                        finish(.stopped(.packetOverflow))
                        return
                    }
                }
                for offset in stride(from: 0, to: packets.count, by: 64) {
                    guard driver?.send(Array(packets[offset..<min(offset + 64, packets.count)])) == true else {
                        finish(.stopped(.packetOverflow))
                        return
                    }
                }
                readNext()
            }
        }
    }

    private func finish(_ result: VPNEvent) {
        guard phase != .finished else { return }
        if terminal == nil { terminal = result }
        phase = .stopping
        readPending = nil
        if !workerFinished { driver?.stop() }
        completeStopIfPossible()
    }

    private func completeStopIfPossible() {
        guard phase == .stopping, workerFinished, settingsPending == nil else { return }
        if settingsInstalled {
            guard !clearStarted else { return }
            clearStarted = true
            let request = UUID()
            settingsPending = request
            io.apply(nil) { [self] success in
                queue.async { [self] in
                    guard settingsPending == request else { return }
                    settingsPending = nil
                    settingsInstalled = false
                    if !success { terminal = .stopped(.networkSettings) }
                    completeStopIfPossible()
                }
            }
            return
        }
        phase = .finished
        driver = nil
        if let terminal { event(terminal) }
    }

    deinit { driver?.stop() }
}

/// The native completion is called only on the connection queue, once per request.
private final class SettingsReply: @unchecked Sendable {
    private let body: (Bool) -> Void
    init(_ body: @escaping (Bool) -> Void) { self.body = body }
    func complete(_ success: Bool) { body(success) }
}
