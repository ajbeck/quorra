import Foundation
import Network

public enum IMDSTCPRelayError: LocalizedError {
    case invalidAddress(String)
    case invalidConnectionLimit(Int)
    case invalidPort(Int)
    case network(NWError)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress(let address):
            return "\(address) is not a valid IP address."
        case .invalidConnectionLimit(let limit):
            return "\(limit) is not a valid relay connection limit."
        case .invalidPort(let port):
            return "\(port) is not a valid TCP port."
        case .network(let error):
            return "The metadata TCP relay failed: \(error.localizedDescription)"
        }
    }
}

@MainActor
public protocol IMDSTCPRelaying: AnyObject {
    func start() async throws
    func stop()
}

@MainActor
public final class IMDSTCPRelay {
    private let publicAddress: String
    private let publicPort: Int
    private let backendAddress: String
    private let backendPort: Int
    private let maximumConnections: Int
    private let queue = DispatchQueue.main

    private var listener: NWListener?
    private var connections: [UUID: RelayConnection] = [:]
    private var startContinuation: CheckedContinuation<Void, Error>?

    public private(set) var boundPort: Int

    public init(
        publicAddress: String = IMDSNetworkConfiguration.publicAddress,
        publicPort: Int = IMDSNetworkConfiguration.publicPort,
        backendAddress: String = IMDSNetworkConfiguration.backendAddress,
        backendPort: Int = IMDSNetworkConfiguration.backendPort,
        maximumConnections: Int = 128
    ) {
        self.publicAddress = publicAddress
        self.publicPort = publicPort
        self.backendAddress = backendAddress
        self.backendPort = backendPort
        self.maximumConnections = maximumConnections
        boundPort = publicPort
    }

    public func start() async throws {
        guard listener == nil else { return }
        guard maximumConnections > 0 else {
            throw IMDSTCPRelayError.invalidConnectionLimit(maximumConnections)
        }

        let publicEndpoint = try endpoint(address: publicAddress, port: publicPort)
        _ = try endpoint(address: backendAddress, port: backendPort)

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = publicEndpoint
        let listener = try NWListener(using: parameters)
        self.listener = listener

        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleListenerState(state)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.accept(connection)
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        startContinuation?.resume(throwing: CancellationError())
        startContinuation = nil
        listener?.cancel()
        listener = nil
        let openConnections = connections.values
        connections.removeAll()
        for connection in openConnections {
            connection.cancel()
        }
    }

    private func endpoint(address: String, port: Int) throws -> NWEndpoint {
        let host: NWEndpoint.Host
        if let address = IPv4Address(address) {
            host = .ipv4(address)
        } else if let address = IPv6Address(address) {
            host = .ipv6(address)
        } else {
            throw IMDSTCPRelayError.invalidAddress(address)
        }

        guard let port = UInt16(exactly: port),
              let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw IMDSTCPRelayError.invalidPort(port)
        }
        return .hostPort(host: host, port: nwPort)
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let rawPort = listener?.port?.rawValue {
                boundPort = Int(rawPort)
            }
            startContinuation?.resume()
            startContinuation = nil
        case .failed(let error):
            startContinuation?.resume(throwing: IMDSTCPRelayError.network(error))
            startContinuation = nil
            stop()
        case .cancelled:
            startContinuation?.resume(throwing: CancellationError())
            startContinuation = nil
        default:
            break
        }
    }

    private func accept(_ client: NWConnection) {
        guard connections.count < maximumConnections else {
            client.cancel()
            return
        }

        let backendHost: NWEndpoint.Host
        if let address = IPv4Address(backendAddress) {
            backendHost = .ipv4(address)
        } else if let address = IPv6Address(backendAddress) {
            backendHost = .ipv6(address)
        } else {
            client.cancel()
            return
        }
        guard let rawPort = UInt16(exactly: backendPort),
              let backendPort = NWEndpoint.Port(rawValue: rawPort) else {
            client.cancel()
            return
        }

        let id = UUID()
        let backend = NWConnection(host: backendHost, port: backendPort, using: .tcp)
        let relay = RelayConnection(
            client: client,
            backend: backend,
            queue: queue
        ) { [weak self] in
            self?.connections[id] = nil
        }
        connections[id] = relay
        relay.start()
    }
}

@MainActor
private final class RelayConnection {
    private let client: NWConnection
    private let backend: NWConnection
    private let queue: DispatchQueue
    private let onFinish: @MainActor () -> Void
    private var backendIsReady = false
    private var clientIsReady = false
    private var hasStartedForwarding = false
    private var completedDirections = 0
    private var isFinished = false

    init(
        client: NWConnection,
        backend: NWConnection,
        queue: DispatchQueue,
        onFinish: @escaping @MainActor () -> Void
    ) {
        self.client = client
        self.backend = backend
        self.queue = queue
        self.onFinish = onFinish
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleClientState(state)
            }
        }
        backend.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleBackendState(state)
            }
        }
        client.start(queue: queue)
        backend.start(queue: queue)
    }

    func cancel() {
        finish()
    }

    private func handleClientState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            clientIsReady = true
            beginForwardingIfReady()
        case .waiting, .failed, .cancelled:
            finish()
        default:
            break
        }
    }

    private func handleBackendState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            backendIsReady = true
            beginForwardingIfReady()
        case .waiting, .failed, .cancelled:
            finish()
        default:
            break
        }
    }

    private func beginForwardingIfReady() {
        guard clientIsReady, backendIsReady, !hasStartedForwarding else { return }
        hasStartedForwarding = true
        forward(from: client, to: backend)
        forward(from: backend, to: client)
    }

    private func forward(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self, weak source, weak destination] data, _, isComplete, error in
            Task { @MainActor [weak self, weak source, weak destination] in
                guard let self, let source, let destination, !self.isFinished else { return }
                guard error == nil else {
                    self.finish()
                    return
                }

                if let data, !data.isEmpty {
                    destination.send(
                        content: data,
                        contentContext: .defaultMessage,
                        isComplete: isComplete,
                        completion: .contentProcessed { [weak self, weak source, weak destination] error in
                            Task { @MainActor [weak self, weak source, weak destination] in
                                guard let self, let source, let destination else { return }
                                guard error == nil else {
                                    self.finish()
                                    return
                                }
                                self.continueOrComplete(
                                    isComplete: isComplete,
                                    source: source,
                                    destination: destination
                                )
                            }
                        }
                    )
                } else if isComplete {
                    destination.send(
                        content: nil,
                        contentContext: .defaultMessage,
                        isComplete: true,
                        completion: .contentProcessed { [weak self] error in
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                if error == nil {
                                    self.completeDirection()
                                } else {
                                    self.finish()
                                }
                            }
                        }
                    )
                } else {
                    self.forward(from: source, to: destination)
                }
            }
        }
    }

    private func continueOrComplete(
        isComplete: Bool,
        source: NWConnection,
        destination: NWConnection
    ) {
        if isComplete {
            completeDirection()
        } else {
            forward(from: source, to: destination)
        }
    }

    private func completeDirection() {
        completedDirections += 1
        if completedDirections == 2 {
            finish()
        }
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        client.stateUpdateHandler = nil
        backend.stateUpdateHandler = nil
        client.cancel()
        backend.cancel()
        onFinish()
    }
}

extension IMDSTCPRelay: IMDSTCPRelaying {}
