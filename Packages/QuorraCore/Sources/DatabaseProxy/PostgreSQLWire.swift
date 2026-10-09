import Foundation
import IAMIdentityCenter
import Network

public nonisolated enum ProxyError: Error, LocalizedError, Equatable {
    case malformedMessage, unsupportedProtocol, localAuthentication, databaseMismatch
    case upstreamTLS, upstreamAuthentication, upstreamUnavailable, disconnected, timedOut, portInUse, stopped
    case upstreamPasswordAuthentication, unsupportedAuthentication
    case malformedMySQLMessage, unsupportedMySQLProtocol, mysqlAuthenticationRequiresTLS
    case localListenerUnavailable

    public var errorDescription: String? {
        switch self {
        case .malformedMessage: "An invalid PostgreSQL message was received."
        case .unsupportedProtocol: "This endpoint supports PostgreSQL protocol 3 and regular database sessions."
        case .localAuthentication: "The local username or password was not accepted. Use quorra and the connection’s local password."
        case .databaseMismatch: "Use the database configured for this local endpoint."
        case .upstreamTLS: "The upstream TLS connection could not be verified. Check the hostname and certificate trust selection."
        case .upstreamAuthentication: "The upstream database rejected IAM authentication. Check IAM database authentication, rds-db:connect, and the database user’s grants."
        case .upstreamPasswordAuthentication: "The upstream database password login failed. Check the selected credential, username, password, and database access."
        case .unsupportedAuthentication: "The upstream authentication method is unsupported. Use SCRAM-SHA-256, MD5, or password authentication."
        case .malformedMySQLMessage: "The MySQL handshake was malformed or out of sequence."
        case .unsupportedMySQLProtocol: "This MySQL connection requested unsupported capabilities or authentication. Compression, local TLS and legacy protocol versions are not supported."
        case .mysqlAuthenticationRequiresTLS: "This MySQL authentication exchange requires verified TLS. Enable upstream TLS for this connection."
        case .upstreamUnavailable: "The upstream database could not be reached. Check its hostname, port, VPN, and network access."
        case .disconnected: "The database connection was closed."
        case .timedOut: "The database handshake timed out."
        case .portInUse: "The local port is already in use. Choose another port."
        case .localListenerUnavailable: "The localhost listener could not be started. Check the local port and retry."
        case .stopped: "The local endpoint is stopped."
        }
    }
}

nonisolated enum PostgreSQLWire {
    static let protocolVersion: UInt32 = 196608
    static let sslRequest: UInt32 = 80877103
    static let gssRequest: UInt32 = 80877104
    static let cancelRequest: UInt32 = 80877102
    static let maximumStartup = 10_000
    static let maximumHandshakeMessage = 1_048_576

    static func integer(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    static func uint32(_ data: Data) throws -> UInt32 {
        guard data.count == 4 else { throw ProxyError.malformedMessage }
        return data.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func message(_ type: UInt8, _ body: Data = Data()) -> Data {
        Data([type]) + integer(UInt32(body.count + 4)) + body
    }

    static func authentication(_ code: UInt32, data: Data = Data()) -> Data { message(82, integer(code) + data) }

    static func startup(_ parameters: [String: String]) -> Data {
        var payload = integer(protocolVersion)
        for key in parameters.keys.sorted() {
            payload.append(Data(key.utf8)); payload.append(0)
            payload.append(Data(parameters[key]!.utf8)); payload.append(0)
        }
        payload.append(0)
        return integer(UInt32(payload.count + 4)) + payload
    }

    static func parameters(_ data: Data) throws -> [String: String] {
        guard data.last == 0 else { throw ProxyError.malformedMessage }
        var result: [String: String] = [:]
        var cursor = data.startIndex
        while cursor < data.endIndex {
            guard let end = data[cursor...].firstIndex(of: 0) else { throw ProxyError.malformedMessage }
            if cursor == end {
                guard end == data.index(before: data.endIndex) else { throw ProxyError.malformedMessage }
                return result
            }
            guard let name = String(data: data[cursor..<end], encoding: .utf8), result[name] == nil else { throw ProxyError.malformedMessage }
            cursor = data.index(after: end)
            guard cursor < data.endIndex, let valueEnd = data[cursor...].firstIndex(of: 0),
                  let value = String(data: data[cursor..<valueEnd], encoding: .utf8) else { throw ProxyError.malformedMessage }
            result[name] = value
            cursor = data.index(after: valueEnd)
        }
        throw ProxyError.malformedMessage
    }

    static func error(_ error: any Error) -> Data {
        let message: String
        let state: String
        if let failure = error as? ProxyError {
            message = failure.localizedDescription
            state = failure == .localAuthentication ? "28P01" : "08006"
        } else if error is IAMIdentityCenterError {
            message = "Quorra’s AWS credentials are unavailable. Open Quorra to check the session."
            state = "08006"
        } else {
            message = "Quorra could not establish the database connection."
            state = "08006"
        }
        return self.message(69, Data("SFATAL\0VFATAL\0C\(state)\0M\(message)\0\0".utf8))
    }
}

/// One reader and one writer per socket. Each receive is bounded, and each send
/// awaits Network.framework's backpressure before accepting another relay chunk.
actor PostgreSQLSocket {
    nonisolated let connection: NWConnection
    private var ready: CheckedContinuation<Void, any Error>?
    private var terminalFailure: ProxyError?

    init(_ connection: NWConnection) { self.connection = connection }
    nonisolated func close() { connection.cancel() }

    func start() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                connection.stateUpdateHandler = { [weak self] state in Task { await self?.stateChanged(state) } }
                connection.start(queue: DispatchQueue(label: "dev.ajbeck.quorra.postgresql.socket"))
                if Task.isCancelled { connection.cancel() }
            }
        } onCancel: { connection.cancel() }
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            if terminalFailure == nil { ready?.resume(); ready = nil }
        case .waiting(let error), .failed(let error):
            // Network.framework can wait for a new path after a TLS failure.
            // A database handshake is a single attempt; surface the error and
            // cancel now so pending I/O cannot wait indefinitely for a retry.
            let failure: ProxyError
            if case .tls = error { failure = .upstreamTLS } else { failure = .upstreamUnavailable }
            terminalFailure = terminalFailure ?? failure
            ready?.resume(throwing: failure); ready = nil
            connection.cancel()
        case .cancelled:
            ready?.resume(throwing: terminalFailure ?? CancellationError()); ready = nil
        default: break
        }
    }

    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        if let terminalFailure { throw terminalFailure }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    connection.send(content: data, completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    })
                }
            } onCancel: { connection.cancel() }
        } catch { throw ioFailure(error) }
    }

    func chunk(maximum: Int = 65_536) async throws -> Data? {
        try Task.checkCancellation()
        if let terminalFailure { throw terminalFailure }
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, complete, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let data, !data.isEmpty { continuation.resume(returning: data) }
                        else if complete { continuation.resume(returning: nil) }
                        else { continuation.resume(throwing: ProxyError.disconnected) }
                    }
                }
            } onCancel: { connection.cancel() }
        } catch { throw ioFailure(error) }
    }

    private func ioFailure(_ error: any Error) -> any Error {
        if Task.isCancelled { return CancellationError() }
        if let terminalFailure { return terminalFailure }
        if let error = error as? NWError, case .tls = error { return ProxyError.upstreamTLS }
        return ProxyError.disconnected
    }

    func exact(_ count: Int) async throws -> Data {
        guard (0...PostgreSQLWire.maximumHandshakeMessage).contains(count) else { throw ProxyError.malformedMessage }
        var data = Data()
        while data.count < count {
            guard let next = try await chunk(maximum: count - data.count) else { throw ProxyError.disconnected }
            data.append(next)
        }
        return data
    }

    func message() async throws -> (type: UInt8, body: Data) {
        let header = try await exact(5)
        let size = Int(try PostgreSQLWire.uint32(Data(header.suffix(4))))
        guard (4...PostgreSQLWire.maximumHandshakeMessage).contains(size) else { throw ProxyError.malformedMessage }
        return (header[header.startIndex], try await exact(size - 4))
    }
}

/// PostgreSQL's SSLRequest runs before TLS. Apple documents dynamically adding
/// TLS above a framer while it is waiting to mark the connection ready.
nonisolated final class PostgreSQLTLSFramer: NWProtocolFramerImplementation {
    static let label = "Quorra PostgreSQL TLS upgrade"
    static let definition = NWProtocolFramer.Definition(implementation: PostgreSQLTLSFramer.self)
    private let tls: NWProtocolTLS.Options?
    private var upgraded = false

    init(framer: NWProtocolFramer.Instance) { tls = framer.options["tlsOptions"] as? NWProtocolTLS.Options }

    static func options(tls: NWProtocolTLS.Options) -> NWProtocolFramer.Options {
        let options = NWProtocolFramer.Options(definition: definition)
        options["tlsOptions"] = tls
        return options
    }

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        framer.writeOutput(data: PostgreSQLWire.integer(8) + PostgreSQLWire.integer(PostgreSQLWire.sslRequest))
        framer.scheduleWakeup(wakeupTime: .milliseconds(30_000))
        return .willMarkReady
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        guard !upgraded else { return 0 }
        var response: UInt8?
        _ = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 1) { buffer, _ in
            guard let buffer, !buffer.isEmpty else { return 0 }
            response = buffer[0]
            return 1
        }
        guard let response else { return 1 }
        guard response == 83, let tls else { framer.markFailed(error: .tls(-9807)); return 0 }
        do { try framer.prependApplicationProtocol(options: tls) }
        catch { framer.markFailed(error: .tls(-9807)); return 0 }
        upgraded = true
        framer.passThroughInput()
        framer.passThroughOutput()
        framer.markReady()
        return 0
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        do { try framer.writeOutputNoCopy(length: messageLength) }
        catch { framer.markFailed(error: .posix(.EPROTO)) }
    }

    func wakeup(framer: NWProtocolFramer.Instance) { if !upgraded { framer.markFailed(error: .posix(.ETIMEDOUT)) } }
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}
}
