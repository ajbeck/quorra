import Foundation
import Network
import Synchronization

nonisolated final class MySQLHandshakeState: Sendable {
    struct Result: Sendable {
        var greeting: MySQLWire.Greeting?
        var capabilities: UInt32 = 0
        var sequence: UInt8 = 1
        var failure: ProxyError?
    }
    let value = Mutex(Result())
}

/// Consume the initial server greeting, then issue SSLRequest and add TLS
/// before Network.framework exposes a ready socket to the authentication code.
nonisolated final class MySQLTLSFramer: NWProtocolFramerImplementation {
    static let label = "Quorra MySQL handshake"
    static let definition = NWProtocolFramer.Definition(implementation: MySQLTLSFramer.self)
    private let tls: NWProtocolTLS.Options?
    private let state: MySQLHandshakeState?
    private let capabilities: UInt32
    private let characterSet: UInt8
    private var payloadLength: Int?
    private var finished = false

    init(framer: NWProtocolFramer.Instance) {
        tls = framer.options["tls"] as? NWProtocolTLS.Options
        state = framer.options["state"] as? MySQLHandshakeState
        capabilities = framer.options["capabilities"] as? UInt32 ?? MySQLWire.capabilities
        characterSet = framer.options["characterSet"] as? UInt8 ?? 45
    }

    static func options(tls: NWProtocolTLS.Options?, state: MySQLHandshakeState, capabilities: UInt32, characterSet: UInt8) -> NWProtocolFramer.Options {
        let options = NWProtocolFramer.Options(definition: definition)
        options["tls"] = tls
        options["state"] = state
        options["capabilities"] = capabilities
        options["characterSet"] = characterSet
        return options
    }

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        framer.scheduleWakeup(wakeupTime: .milliseconds(30_000))
        return .willMarkReady
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        guard !finished else { return 0 }
        if payloadLength == nil {
            var header: Data?
            _ = framer.parseInput(minimumIncompleteLength: 4, maximumLength: 4) { buffer, _ in
                guard let buffer, buffer.count == 4 else { return 0 }
                header = Data(buffer); return 4
            }
            guard let header else { return 4 }
            let length = Int(header[0]) | (Int(header[1]) << 8) | (Int(header[2]) << 16)
            guard header[3] == 0, (1...MySQLWire.maximumHandshake).contains(length) else {
                fail(.malformedMySQLMessage, framer); return 0
            }
            payloadLength = length
        }
        let count = payloadLength!
        var payload: Data?
        _ = framer.parseInput(minimumIncompleteLength: count, maximumLength: count) { buffer, _ in
            guard let buffer, buffer.count == count else { return 0 }
            payload = Data(buffer); return count
        }
        guard let payload else { return count }
        do {
            if payload.first == 255 { throw ProxyError.upstreamUnavailable }
            let greeting = try MySQLWire.Greeting(payload)
            // Handshake-only flags may be adjusted. Result/command flags must
            // agree so the byte relay preserves the client's protocol format.
            let negotiable = MySQLWire.connectAttributes | MySQLWire.lengthEncodedAuth | MySQLWire.connectWithDB
            guard (capabilities & ~negotiable) & ~greeting.capabilities == 0 else { throw ProxyError.unsupportedMySQLProtocol }
            var chosen = capabilities & greeting.capabilities
            chosen |= MySQLWire.connectWithDB
            if let tls {
                guard greeting.capabilities & MySQLWire.ssl != 0 else { throw ProxyError.upstreamTLS }
                chosen |= MySQLWire.ssl
                framer.writeOutput(data: MySQLWire.packet(MySQLWire.header(capabilities: chosen, characterSet: characterSet), sequence: 1))
                try framer.prependApplicationProtocol(options: tls)
            }
            state?.value.withLock {
                $0.greeting = greeting
                $0.capabilities = chosen
                $0.sequence = tls == nil ? 1 : 2
            }
            finished = true
            framer.passThroughInput(); framer.passThroughOutput(); framer.markReady()
        } catch {
            fail(error as? ProxyError ?? .upstreamTLS, framer)
        }
        return 0
    }

    private func fail(_ failure: ProxyError, _ framer: NWProtocolFramer.Instance) {
        state?.value.withLock { $0.failure = failure }
        framer.markFailed(error: failure == .upstreamTLS ? .tls(-9807) : .posix(.EPROTO))
    }
    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        do { try framer.writeOutputNoCopy(length: messageLength) } catch { fail(.upstreamUnavailable, framer) }
    }
    func wakeup(framer: NWProtocolFramer.Instance) { if !finished { fail(.timedOut, framer) } }
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}
}
