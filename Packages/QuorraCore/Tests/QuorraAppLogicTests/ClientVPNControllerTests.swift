import ClientVPN
import Foundation
import Observation
import QuorraTestSupport
import Testing
@testable import QuorraAppLogic

@Suite("Client VPN controller", .timeLimit(.minutes(1)))
@MainActor
struct ClientVPNControllerTests {
    private let challenge = ClientVPNBrowserChallenge(id: UUID(), url: URL(string: "https://signin.example.invalid/saml")!)
    private let token = ClientVPNLiveToken(username: Data("user".utf8), token: Data("token".utf8))

    /// A tunnel that asks for the browser on connect and runs once the assertion arrives.
    private func browserTunnel() -> FakeTunnel {
        let tunnel = FakeTunnel()
        tunnel.onRequest = { [unowned tunnel, challenge, token] request in
            switch request {
            case .connect: tunnel.phase = .authenticating; tunnel.challenge = challenge
            case .authenticate: tunnel.phase = .running; tunnel.challenge = nil; tunnel.token = token
            case .status, .stop: break
            }
            return nil
        }
        return tunnel
    }

    @Test func connectsThroughTheBrowserAndReportsATunnelDrop() async throws {
        let tunnel = browserTunnel()
        let signIn = FakeSignIn(assertion: Data("assertion".utf8))
        let controller = ClientVPNController(transport: tunnel, signIn: signIn, clock: ManualClock())
        controller.connect(profileName: "work", profile: "client")
        await reach(controller, .connected)
        let run = try #require(tunnel.started.first)
        #expect(signIn.answered == [challenge.id] && signIn.profileNames == ["work"])
        #expect(tunnel.requests.contains(.authenticate(run: run, challenge: challenge.id, assertion: Data("assertion".utf8))))
        #expect(controller.hasSessionToken(for: "client") && !controller.hasSessionToken(for: "other"))

        tunnel.failure = .transport
        tunnel.status = .disconnected
        await reach(controller, .failed(.transport))
        #expect(tunnel.stops == 1)
    }

    @Test func disconnectingStopsTheTunnel() async {
        let tunnel = browserTunnel()
        let controller = ClientVPNController(transport: tunnel, signIn: FakeSignIn(assertion: Data([1])), clock: ManualClock())
        controller.connect(profileName: "work", profile: "client")
        await reach(controller, .connected)
        await controller.disconnect()
        #expect(controller.state == .disconnected && tunnel.stops == 1)
    }

    @Test func retriesTheProfileUntilTheProviderIsReady() async {
        let tunnel = FakeTunnel()
        let clock = ManualClock()
        var refusals = 2
        tunnel.onRequest = { [unowned tunnel] request in
            guard case .connect = request else { return nil }
            if refusals > 0 {
                refusals -= 1
                return .rejected(.staleRequest)
            }
            tunnel.phase = .running
            return nil
        }
        let controller = ClientVPNController(transport: tunnel, signIn: FakeSignIn(assertion: Data([1])), clock: clock)
        controller.connect(profileName: "work", profile: "client")
        for _ in 0..<2 {
            await clock.sleeperArrived()
            clock.advance(by: .milliseconds(250))
        }
        await reach(controller, .connected)
        #expect(tunnel.requests.filter { if case .connect = $0 { true } else { false } }.count == 3)
    }

    @Test func aRefusedProfileIsNotRetried() async {
        let tunnel = FakeTunnel()
        tunnel.onRequest = { request in
            if case .connect = request { .rejected(.invalidProfile) } else { nil }
        }
        let controller = ClientVPNController(transport: tunnel, signIn: FakeSignIn(assertion: Data([1])), clock: ManualClock())
        controller.connect(profileName: "work", profile: "client")
        await reach(controller, .failed(.invalidProfile))
        #expect(tunnel.requests.count == 1 && tunnel.stops == 1)
    }

    @Test func aStoppedTunnelAbandonsTheBrowserSignIn() async {
        let tunnel = browserTunnel()
        let signIn = FakeSignIn(assertion: nil)
        let controller = ClientVPNController(transport: tunnel, signIn: signIn, clock: ManualClock())
        controller.connect(profileName: "work", profile: "client")
        await reach(controller, .signingIn)
        tunnel.failure = .timedOut
        tunnel.status = .disconnected
        await reach(controller, .failed(.timedOut))
        #expect(signIn.wasCancelled)
    }

    @Test func aRefusedSessionTokenIsForgotten() async throws {
        let tunnel = browserTunnel()
        let controller = ClientVPNController(transport: tunnel, signIn: FakeSignIn(assertion: Data([1])), clock: ManualClock())
        controller.connect(profileName: "work", profile: "client")
        await reach(controller, .connected)
        await controller.disconnect()

        tunnel.phase = .awaitingProfile
        tunnel.token = nil
        controller.connect(profileName: "work", profile: "client", usingSessionToken: true)
        await reach(controller, .failed(.authentication))
        let run = try #require(tunnel.started.last)
        #expect(tunnel.requests.contains(.connect(run: run, profile: "client", token: token)))
        #expect(!controller.hasSessionToken(for: "client"))
    }

    @Test func reconnectingWithoutATokenFailsBeforeStarting() {
        let tunnel = FakeTunnel()
        let controller = ClientVPNController(transport: tunnel, signIn: FakeSignIn(assertion: Data([1])), clock: ManualClock())
        controller.connect(profileName: "work", profile: "client", usingSessionToken: true)
        #expect(controller.state == .failed(.authentication) && tunnel.started.isEmpty)
    }

    private func reach(_ controller: ClientVPNController, _ expected: ClientVPNController.State) async {
        for await state in Observations({ controller.state }) where state == expected {
            return
        }
    }
}

/// A tunnel whose provider answers from settable state; `onRequest` can change that state or override the reply.
@MainActor
private final class FakeTunnel: ClientVPNTransport {
    var status = ClientVPNTunnelStatus.disconnected {
        didSet { for watcher in watchers { watcher.yield(status) } }
    }
    var phase = ClientVPNLivePhase.awaitingProfile
    var challenge: ClientVPNBrowserChallenge?
    var token: ClientVPNLiveToken?
    var failure: ClientVPNLiveFailure?
    var onRequest: (ClientVPNLiveRequest) -> ClientVPNLiveResponse? = { _ in nil }
    private(set) var started: [UUID] = []
    private(set) var requests: [ClientVPNLiveRequest] = []
    private(set) var stops = 0
    private var watchers: [AsyncStream<ClientVPNTunnelStatus>.Continuation] = []

    func statusChanges() -> AsyncStream<ClientVPNTunnelStatus> {
        let (stream, continuation) = AsyncStream<ClientVPNTunnelStatus>.makeStream()
        watchers.append(continuation)
        return stream
    }

    func start(run: UUID) async throws {
        started.append(run)
        status = .connecting
    }

    func send(_ request: ClientVPNLiveRequest) async throws -> ClientVPNLiveResponse {
        requests.append(request)
        if let reply = onRequest(request) { return reply }
        return .snapshot(ClientVPNLiveSnapshot(run: request.run, phase: phase, challenge: challenge, token: token, failure: failure))
    }

    func stop() async {
        stops += 1
        status = .disconnected
    }

    func lastFailure() async -> ClientVPNLiveFailure? { failure }
}

/// Returns `assertion` at once, or with nil waits until cancelled.
@MainActor
private final class FakeSignIn: ClientVPNSignIn {
    private let assertion: Data?
    private(set) var answered: [UUID] = []
    private(set) var profileNames: [String] = []
    private(set) var wasCancelled = false

    init(assertion: Data?) {
        self.assertion = assertion
    }

    func assertion(for challenge: ClientVPNBrowserChallenge, profileName: String) async throws -> Data {
        answered.append(challenge.id)
        profileNames.append(profileName)
        if let assertion { return assertion }
        do {
            try await Task.sleep(for: .seconds(3600))
        } catch {
            wasCancelled = true
            throw error
        }
        return Data()
    }
}
