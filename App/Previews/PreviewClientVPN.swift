#if DEBUG
import ClientVPN
import Foundation
import QuorraAppLogic

extension ClientVPNController {
    /// A controller whose tunnel never starts, for previews.
    static func preview() -> ClientVPNController {
        ClientVPNController(transport: PreviewClientVPNTransport(), signIn: ClientVPNBrowserSignIn(open: { _ in false }))
    }
}

extension ClientVPNProfileSecrets {
    static let preview = ClientVPNProfileSecrets(keychain: PreviewKeychain())
}

@MainActor
private final class PreviewClientVPNTransport: ClientVPNTransport {
    let status = ClientVPNTunnelStatus.disconnected
    let connectedDate: Date? = nil

    func statusChanges() -> AsyncStream<ClientVPNTunnelStatus> { AsyncStream { $0.finish() } }
    func start(run: UUID) async throws { throw ClientVPNLiveFailure.transport }
    func send(_ request: ClientVPNLiveRequest) async throws -> ClientVPNLiveResponse { .rejected(.transport) }
    func stop() async {}
    func lastFailure() async -> ClientVPNLiveFailure? { nil }
}
#endif
