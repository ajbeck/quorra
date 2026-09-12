import Foundation
import Network

@MainActor
public protocol IMDSBackendProbing {
    func probe() async throws
}

public enum IMDSBackendProbeError: LocalizedError, Equatable {
    case invalidAddress(String)
    case invalidPort(Int)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress(let address):
            return "\(address) is not a valid backend IP address."
        case .invalidPort(let port):
            return "\(port) is not a valid backend TCP port."
        case .unavailable(let reason):
            return "The Quorra IMDS backend is unavailable: \(reason)"
        }
    }
}

@MainActor
public struct NetworkIMDSBackendProbe: IMDSBackendProbing {
    private let address: String
    private let port: Int
    private let timeout: Int

    public init(
        address: String = IMDSNetworkConfiguration.backendAddress,
        port: Int = IMDSNetworkConfiguration.backendPort,
        timeout: Int = 2
    ) {
        self.address = address
        self.port = port
        self.timeout = timeout
    }

    public func probe() async throws {
        let host: NWEndpoint.Host
        if let address = IPv4Address(address) {
            host = .ipv4(address)
        } else if let address = IPv6Address(address) {
            host = .ipv6(address)
        } else {
            throw IMDSBackendProbeError.invalidAddress(address)
        }
        guard let rawPort = UInt16(exactly: port),
              let port = NWEndpoint.Port(rawValue: rawPort) else {
            throw IMDSBackendProbeError.invalidPort(port)
        }

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = timeout
        let parameters = NWParameters(tls: nil, tcp: tcp)
        let connection = NWConnection(host: host, port: port, using: parameters)
        let attempt = BackendProbeAttempt(connection: connection)
        try await attempt.run()
    }
}

@MainActor
private final class BackendProbeAttempt {
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Void, Error>?

    init(connection: NWConnection) {
        self.connection = connection
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handle(state)
                }
            }
            connection.start(queue: .main)
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            finish(with: .success(()))
        case .waiting(let error), .failed(let error):
            finish(with: .failure(.unavailable(error.localizedDescription)))
        case .cancelled:
            finish(with: .failure(.unavailable("the connection was cancelled")))
        default:
            break
        }
    }

    private func finish(with result: Result<Void, IMDSBackendProbeError>) {
        guard let continuation else { return }
        self.continuation = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result.mapError { $0 as Error })
    }
}
