import Foundation
import Network
import NetworkExtension

final class AppProxyProvider: NETransparentProxyProvider {
    private enum Endpoint {
        static let publicAddress = IPv4Address("169.254.169.254")!
        static let publicAddressString = "169.254.169.254"
        static let publicPrefix = 32
        static let publicPort = Network.NWEndpoint.Port.http
        static let backendAddress = IPv4Address.loopback
        static let backendPort = Network.NWEndpoint.Port(rawValue: 7_114)!
    }

    private let relays = TCPFlowRelayStore(maximumCount: 128)

    override func startProxy(
        options: [String: Any]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let destination = Network.NWEndpoint.hostPort(
            host: .ipv4(Endpoint.publicAddress),
            port: Endpoint.publicPort
        )
        let rule = NENetworkRule(
            destinationNetworkEndpoint: destination,
            prefix: Endpoint.publicPrefix,
            protocol: .TCP
        )
        let settings = NETransparentProxyNetworkSettings(
            tunnelRemoteAddress: Endpoint.publicAddressString
        )
        settings.includedNetworkRules = [rule]

        setTunnelNetworkSettings(settings, completionHandler: completionHandler)
    }

    override func stopProxy(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        relays.cancelAll()
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard let tcpFlow = flow as? NEAppProxyTCPFlow else {
            return false
        }

        let relayID = UUID()
        let relay = TCPFlowRelay(
            flow: tcpFlow,
            backendHost: .ipv4(Endpoint.backendAddress),
            backendPort: Endpoint.backendPort
        ) { [weak relays] in
            relays?.remove(id: relayID)
        }
        guard relays.insert(relay, id: relayID) else {
            return false
        }

        relay.start()
        return true
    }
}

private final class TCPFlowRelayStore: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumCount: Int
    private var relays: [UUID: TCPFlowRelay] = [:]

    init(maximumCount: Int) {
        self.maximumCount = maximumCount
    }

    func insert(_ relay: TCPFlowRelay, id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard relays.count < maximumCount else { return false }
        relays[id] = relay
        return true
    }

    func remove(id: UUID) {
        lock.lock()
        relays[id] = nil
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let activeRelays = Array(relays.values)
        relays.removeAll()
        lock.unlock()

        for relay in activeRelays {
            relay.cancel()
        }
    }
}

private final class TCPFlowRelay: @unchecked Sendable {
    private static let maximumReadLength = 64 * 1_024

    private let flow: NEAppProxyTCPFlow
    private let backendConnection: NWConnection
    private let queue = DispatchQueue(label: "dev.ajbeck.quorra.imds-proxy.flow")
    private let onStop: @Sendable () -> Void
    private var hasStopped = false

    init(
        flow: NEAppProxyTCPFlow,
        backendHost: Network.NWEndpoint.Host,
        backendPort: Network.NWEndpoint.Port,
        onStop: @escaping @Sendable () -> Void
    ) {
        self.flow = flow
        self.backendConnection = NWConnection(
            host: backendHost,
            port: backendPort,
            using: .tcp
        )
        self.onStop = onStop
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            backendConnection.stateUpdateHandler = { [weak self] state in
                self?.handleBackendState(state)
            }
            backendConnection.start(queue: queue)
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.stop(error: nil)
        }
    }

    private func handleBackendState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            flow.open(withLocalFlowEndpoint: nil) { [weak self] error in
                self?.queue.async {
                    guard let self else { return }
                    if let error {
                        self.stop(error: error)
                    } else {
                        self.readFromClient()
                        self.readFromBackend()
                    }
                }
            }
        case .failed(let error):
            stop(error: error)
        case .cancelled:
            stop(error: nil)
        case .setup, .preparing, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func readFromClient() {
        guard !hasStopped else { return }
        flow.readData { [weak self] data, error in
            self?.queue.async {
                guard let self, !self.hasStopped else { return }
                if let error {
                    self.stop(error: error)
                    return
                }
                guard let data, !data.isEmpty else {
                    self.backendConnection.send(
                        content: nil,
                        contentContext: .finalMessage,
                        isComplete: true,
                        completion: .contentProcessed { [weak self] error in
                            self?.queue.async {
                                if let error {
                                    self?.stop(error: error)
                                }
                            }
                        }
                    )
                    return
                }

                self.backendConnection.send(content: data, completion: .contentProcessed { [weak self] error in
                    self?.queue.async {
                        guard let self else { return }
                        if let error {
                            self.stop(error: error)
                        } else {
                            self.readFromClient()
                        }
                    }
                })
            }
        }
    }

    private func readFromBackend() {
        guard !hasStopped else { return }
        backendConnection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.maximumReadLength
        ) { [weak self] data, _, isComplete, error in
            self?.queue.async {
                guard let self, !self.hasStopped else { return }
                if let error {
                    self.stop(error: error)
                    return
                }

                guard let data, !data.isEmpty else {
                    if isComplete {
                        self.stop(error: nil)
                    } else {
                        self.readFromBackend()
                    }
                    return
                }

                self.flow.write(data) { [weak self] error in
                    self?.queue.async {
                        guard let self else { return }
                        if let error {
                            self.stop(error: error)
                        } else if isComplete {
                            self.stop(error: nil)
                        } else {
                            self.readFromBackend()
                        }
                    }
                }
            }
        }
    }

    private func stop(error: Error?) {
        guard !hasStopped else { return }
        hasStopped = true
        let proxyError = error as NSError?
        flow.closeReadWithError(proxyError)
        flow.closeWriteWithError(proxyError)
        backendConnection.stateUpdateHandler = nil
        backendConnection.cancel()
        onStop()
    }
}
