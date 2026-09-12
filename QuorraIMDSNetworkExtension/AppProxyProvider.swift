import Network
import NetworkExtension

final class AppProxyProvider: NETransparentProxyProvider {
    private enum Endpoint {
        static let publicAddress = IPv4Address("169.254.169.254")!
        static let publicPrefix = 32
        static let publicPort = NWEndpoint.Port.http
    }

    override func startProxy(
        options: [String: Any]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let destination = NWEndpoint.hostPort(
            host: .ipv4(Endpoint.publicAddress),
            port: Endpoint.publicPort
        )
        let rule = NENetworkRule(
            destinationNetworkEndpoint: destination,
            prefix: Endpoint.publicPrefix,
            protocol: .TCP
        )
        let settings = NETransparentProxyNetworkSettings(
            tunnelRemoteAddress: Endpoint.publicAddress.debugDescription
        )
        settings.includedNetworkRules = [rule]

        setTunnelNetworkSettings(settings, completionHandler: completionHandler)
    }

    override func stopProxy(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        // The network rule is intentionally the first line of defense. Validate
        // the delivered flow again before the relay starts in the next slice.
        return false
    }
}
