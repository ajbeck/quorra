import ClientVPN
import Foundation
import LoopbackCallback
import Network

/// Answers a Client VPN sign-in challenge and returns the SAML assertion for the tunnel.
@MainActor
public protocol ClientVPNSignIn: AnyObject, Sendable {
    func assertion(for challenge: ClientVPNBrowserChallenge, profileName: String) async throws -> Data
}

/// Opens the challenge in the browser and waits for the identity provider's form POST on
/// `127.0.0.1:35001`, the address AWS Client VPN sends it to.
@MainActor
public final class ClientVPNBrowserSignIn: ClientVPNSignIn {
    private let open: @MainActor (URL) -> Bool
    private let port: UInt16

    /// `open` shows the URL in the user's browser and reports whether it could.
    public convenience init(open: @escaping @MainActor (URL) -> Bool) {
        self.init(open: open, port: ClientVPNSAMLCallback.port)
    }

    init(open: @escaping @MainActor (URL) -> Bool, port: UInt16) {
        self.open = open
        self.port = port
    }

    public func assertion(for challenge: ClientVPNBrowserChallenge, profileName: String) async throws -> Data {
        let relayStates = URLComponents(url: challenge.url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "RelayState" } ?? []
        guard challenge.url.scheme?.lowercased() == "https", relayStates.count <= 1,
              let port = NWEndpoint.Port(rawValue: port) else { throw ClientVPNLiveFailure.authentication }
        let relayState = relayStates.first?.value
        let listener = LoopbackCallbackListener<String>(
            port: port,
            limits: ClientVPNSAMLCallback.limits,
            lifetime: .seconds(600),
            unavailable: ClientVPNLiveFailure.callbackUnavailable,
            timedOut: ClientVPNLiveFailure.timedOut,
            rejectedPage: ClientVPNCallbackPage.notAccepted
        ) { request, port in
            do {
                let assertion = try ClientVPNSAMLCallback.assertion(from: request, port: port, relayState: relayState)
                return .init(page: ClientVPNCallbackPage.received(profileName: profileName), outcome: .success(assertion))
            } catch {
                // A stray or forged request must not end the sign-in.
                return .init(page: ClientVPNCallbackPage.notAccepted, outcome: nil)
            }
        }
        _ = try await listener.start()
        guard open(challenge.url) else {
            listener.cancel()
            throw ClientVPNLiveFailure.authentication
        }
        return Data(try await listener.value().utf8)
    }
}
