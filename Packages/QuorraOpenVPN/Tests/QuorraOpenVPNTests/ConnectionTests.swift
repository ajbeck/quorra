@preconcurrency import QuorraOpenVPNNative
import Foundation
import NetworkExtension
import Testing
@testable import QuorraOpenVPN

/// Test doubles are confined to the same serial queue as the real adapter.
private final class MemoryIO: VPNPacketIO, @unchecked Sendable {
    var applies: [Bool] = []
    var replies: [@Sendable (Bool) -> Void] = []
    var reads: [@Sendable ([Data], [Int32]) -> Void] = []
    var readReplies: [@Sendable (Result<VPNPacketBatch, VPNFailure>) -> Void] = []
    var writes: [Data] = []
    var writeSucceeds = true

    func apply(_ settings: NEPacketTunnelNetworkSettings?, completion: @escaping @Sendable (Bool) -> Void) {
        applies.append(settings != nil)
        replies.append(completion)
    }
    func read(completion: @escaping @Sendable (Result<VPNPacketBatch, VPNFailure>) -> Void) {
        readReplies.append(completion)
        reads.append { packets, families in completion(.success(.init(packets: packets, families: families))) }
    }
    func write(_ packet: Data, family: Int32) -> Bool {
        writes.append(packet)
        return writeSucceeds
    }
}

private final class MemoryCore: VPNCoreDriving, @unchecked Sendable {
    weak var delegate: (any QVPNCoreDelegate)?
    var starts = 0
    var stops = 0
    var packets: [[Data]] = []
    var startFailure: Error?
    var sendSucceeds = true

    func start(profile: String, credentials: QVPNCredentials?) throws {
        starts += 1
        if let startFailure { throw startFailure }
    }
    func stop() { stops += 1 }
    func send(_ packets: [Data]) -> Bool { self.packets.append(packets); return sendSucceeds }
}

private final class Harness: @unchecked Sendable {
    let queue = DispatchQueue(label: "vpn-test")
    let io = MemoryIO()
    let core = MemoryCore()
    var events: [VPNEvent] = []
    var replies: [Bool] = []
    lazy var connection = VPNConnection(io: io, queue: queue, event: { [weak self] in self?.events.append($0) }) { [core] delegate, _ in
        core.delegate = delegate
        return core
    }

    func start() { connection.start(profile: "synthetic"); drain() }
    func drain() { queue.sync {} }
    func requestSettings() {
        queue.sync {
            let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "192.0.2.8")
            settings.mtu = 1500
            core.delegate?.applyVPNSettings(settings) { [self] in replies.append($0) }
        }
    }
    func ready() {
        start()
        requestSettings()
        queue.sync { io.replies[0](true) }
        drain()
        queue.sync { core.delegate?.vpnDidConnect() }
    }
}

struct ConnectionTests {
    @Test func packetHostLossStopsInsteadOfSpinningOnEmptyReads() {
        let h = Harness()
        h.ready()
        h.queue.sync { h.io.readReplies[0](.failure(.transport)) }
        h.drain()
        h.queue.sync {
            #expect(h.core.stops == 1 && h.io.reads.count == 1)
            h.core.delegate?.vpnDidStop(.transport)
            h.io.replies[1](true)
        }
        h.drain()
        h.queue.sync {
            guard case .stopped(.transport) = h.events.last else { Issue.record("Missing transport failure"); return }
        }
    }

    @Test func cancellingTheActualCoreWorkerStopsAndRejectsSessionReuse() async throws {
        let profile = try Fixtures.profile().replacingOccurrences(of: "remote vpn.example.invalid 443", with: "remote 127.0.0.1 9")
        let (stream, continuation) = AsyncStream<QVPNFailure>.makeStream()
        let delegate = StopReceiver(continuation: continuation)
        let session = QVPNCoreSession(delegate: delegate, callbackQueue: DispatchQueue(label: "vpn-native-cancel-test"))
        try session.startProfile(profile, credentials: nil)
        session.stop()
        #expect(throws: (any Error).self) { try session.startProfile(profile, credentials: nil) }
        let result = try await withThrowingTaskGroup(of: QVPNFailure.self) { group in
            group.addTask {
                for await result in stream { return result }
                throw VPNFailure.cancelled
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw VPNFailure.transport
            }
            defer { group.cancelAll() }
            return try #require(try await group.next())
        }
        #expect(result == .cancelled)
        #expect(!session.sendPackets([Fixtures.packet()]))
        withExtendedLifetime(delegate) {}
    }

    @Test func settingsMustSucceedBeforeReadinessAndPacketReads() {
        let h = Harness()
        h.start()
        h.requestSettings()
        h.queue.sync {
            #expect(h.events.isEmpty && h.io.reads.isEmpty && h.replies.isEmpty)
            h.io.replies[0](true)
        }
        h.drain()
        h.queue.sync {
            #expect(h.replies == [true])
            #expect(h.events.isEmpty && h.io.reads.isEmpty)
            h.core.delegate?.vpnDidConnect()
            #expect(h.events.count == 1 && h.io.reads.count == 1)
        }
    }

    @Test func prematureConnectedEventFailsClosed() {
        let h = Harness()
        h.start()
        h.queue.sync {
            h.core.delegate?.vpnDidConnect()
            #expect(h.events.isEmpty && h.core.stops == 1)
            h.core.delegate?.vpnDidStop(.networkSettings)
            #expect(h.io.reads.isEmpty)
            guard case .stopped(.networkSettings) = h.events.first else { Issue.record("Missing settings failure"); return }
        }
    }

    @Test func cancellationWaitsForLateSettingsAndClearsThemBeforeTerminalDelivery() {
        let h = Harness()
        h.start()
        h.requestSettings()
        h.connection.stop()
        h.drain()
        h.queue.sync {
            h.core.delegate?.vpnDidStop(.cancelled)
            #expect(h.events.isEmpty)
            h.io.replies[0](true)
        }
        h.drain()
        h.queue.sync {
            #expect(h.replies == [false])
            #expect(h.io.applies == [true, false])
            #expect(h.events.isEmpty)
            h.io.replies[0](true) // Late duplicate cannot acknowledge or install again.
            h.io.replies[1](true)
        }
        h.drain()
        h.queue.sync {
            #expect(h.replies == [false] && h.events.count == 1)
            guard case .stopped(.cancelled) = h.events.first else { Issue.record("Missing cancellation"); return }
            h.core.delegate?.vpnDidConnect()
            #expect(h.events.count == 1 && h.io.reads.isEmpty)
        }
    }

    @Test func rejectedSettingsNeverStartPacketReads() {
        let h = Harness()
        h.start()
        h.requestSettings()
        h.queue.sync { h.io.replies[0](false) }
        h.drain()
        h.queue.sync {
            #expect(h.replies == [false] && h.core.stops == 1)
            h.core.delegate?.vpnDidStop(.networkSettings)
            h.io.replies[1](true)
        }
        h.drain()
        h.queue.sync {
            #expect(h.io.reads.isEmpty)
            guard case .stopped(.networkSettings) = h.events.first else { Issue.record("Missing settings failure"); return }
        }
    }

    @Test func packetsTransferBothDirectionsAndReadsStopAfterCancellation() {
        let h = Harness()
        h.ready()
        let packet = Fixtures.packet()
        h.queue.sync {
            h.io.reads[0](Array(repeating: packet, count: 65), Array(repeating: AF_INET, count: 65))
            h.core.delegate?.writeVPNPacket(packet, protocolFamily: Int(AF_INET))
        }
        h.drain()
        h.queue.sync {
            #expect(h.core.packets.map(\.count) == [64, 1])
            #expect(h.io.writes == [packet] && h.io.reads.count == 2)
        }
        h.connection.stop()
        h.drain()
        h.queue.sync {
            h.io.reads[1]([packet], [AF_INET])
            h.core.delegate?.writeVPNPacket(packet, protocolFamily: Int(AF_INET))
            h.core.delegate?.vpnDidStop(.cancelled)
            h.io.replies[1](true)
        }
        h.drain()
        h.queue.sync {
            #expect(h.io.reads.count == 2 && h.core.packets.count == 2 && h.io.writes.count == 1)
            #expect(h.events.count == 2)
        }
    }

    @Test func packetFamilyMismatchAndCoreBackpressureStopTheAttempt() {
        for wrongFamily in [true, false] {
            let h = Harness()
            h.ready()
            h.queue.sync {
                h.core.sendSucceeds = false
                h.io.reads[0]([Fixtures.packet()], [wrongFamily ? AF_INET6 : AF_INET])
            }
            h.drain()
            h.queue.sync {
                #expect(h.core.stops == 1 && h.io.reads.count == 1)
                h.core.delegate?.vpnDidStop(.cancelled)
                h.io.replies[1](true)
            }
            h.drain()
            h.queue.sync {
                guard case .stopped(.packetOverflow) = h.events.last else { Issue.record("Missing packet failure"); return }
            }
        }
    }

    @Test func tokenAndChallengeAreDeliveredOnlyDuringTheAppropriateLifecycle() throws {
        let h = Harness()
        h.ready()
        h.queue.sync { h.core.delegate?.vpnReceivedToken(Data("synthetic".utf8), username: Data("user".utf8)) }
        h.connection.stop()
        h.drain()
        h.queue.sync {
            h.core.delegate?.vpnReceivedToken(Data("late".utf8), username: Data("user".utf8))
            #expect(h.events.count == 2)
            guard case .token(let token) = h.events.last else { Issue.record("Missing token"); return }
            #expect(!String(reflecting: token).contains("synthetic"))
        }
        let auth = Harness()
        auth.start()
        let challenge = try #require(QVPNCore.parseChallenge(Fixtures.cookie))
        auth.queue.sync {
            auth.core.delegate?.vpnRequiresAuthentication(challenge)
            #expect(auth.io.applies.isEmpty && auth.events.count == 1)
            guard case .authenticationRequired = auth.events.first else { Issue.record("Missing challenge"); return }
        }
    }

    @Test func oneAttemptCannotStartAnotherWorker() {
        let h = Harness()
        h.start()
        h.start()
        h.queue.sync { #expect(h.core.starts == 1) }
    }
}

private final class StopReceiver: NSObject, QVPNCoreDelegate, @unchecked Sendable {
    let continuation: AsyncStream<QVPNFailure>.Continuation
    init(continuation: AsyncStream<QVPNFailure>.Continuation) { self.continuation = continuation }
    func applyVPNSettings(_ settings: NEPacketTunnelNetworkSettings, completion: @escaping (Bool) -> Void) { completion(false) }
    func writeVPNPacket(_ packet: Data, protocolFamily: Int) {}
    func vpnRequiresAuthentication(_ challenge: QVPNChallenge) { continuation.yield(.authentication); continuation.finish() }
    func vpnDidConnect() { continuation.yield(.transport); continuation.finish() }
    func vpnDidStop(_ failure: QVPNFailure) { continuation.yield(failure); continuation.finish() }
    func vpnReceivedToken(_ token: Data, username: Data) {}
}
