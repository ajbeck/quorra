import Foundation
import Synchronization
import Testing
@testable import ClientVPN
import QuorraTestSupport

@Suite("Client VPN live session", .timeLimit(.minutes(1)))
struct ClientVPNLiveSessionTests {
    private static let signInURL = URL(string: "https://signin.example.invalid/saml")!
    private static let cookie = Data("cookie".utf8)

    @Test func connectsAfterBrowserSignIn() async throws {
        var harness = Harness()
        let startup = harness.start()
        await harness.reach(.phase(.awaitingProfile))
        _ = await harness.send(.connect(run: harness.run, profile: "client", token: nil))
        let first = try harness.engines.latest()
        guard case nil = first.credentials else { Issue.record("The first attempt had credentials"); return }
        first.send(.challenge(url: Self.signInURL, cookie: Self.cookie))
        await harness.reach(.phase(.authenticating))
        let challenge = try #require(try await harness.snapshot().challenge)
        #expect(challenge.url == Self.signInURL)

        #expect(await harness.send(.authenticate(run: harness.run, challenge: UUID(), assertion: Data([65]))) == .rejected(.staleRequest))
        _ = await harness.send(.authenticate(run: harness.run, challenge: challenge.id, assertion: Data([65])))
        let second = try harness.engines.latest()
        #expect(second !== first)
        guard case .assertion(let cookie, let response) = second.credentials else { Issue.record("The second attempt had no assertion"); return }
        #expect(cookie == Self.cookie && response == Data([65]))

        first.send(.connected)
        second.send(.connected)
        try await startup.value
        #expect(try await harness.snapshot().phase == .running)
        #expect(await harness.send(.authenticate(run: harness.run, challenge: challenge.id, assertion: Data([65]))) == .rejected(.staleRequest))

        let stopping = Task { [session = harness.session] in await session.stop() }
        await harness.reach(.phase(.stopping))
        #expect(second.stops == 1)
        second.send(.stopped(.cancelled))
        await stopping.value
        #expect(try await harness.snapshot().phase == .stopped)
        #expect(harness.engines.cancellations.isEmpty)
    }

    @Test func stoppingDuringSignInFailsStartupAndForgetsTheChallenge() async throws {
        var harness = Harness()
        let startup = harness.start()
        await harness.reach(.phase(.awaitingProfile))
        _ = await harness.send(.connect(run: harness.run, profile: "client", token: nil))
        try harness.engines.latest().send(.challenge(url: Self.signInURL, cookie: Self.cookie))
        await harness.reach(.phase(.authenticating))
        let challenge = try #require(try await harness.snapshot().challenge)

        await harness.session.stop()
        await #expect(throws: ClientVPNLiveFailure.cancelled) { try await startup.value }
        let stopped = try await harness.snapshot()
        #expect(stopped.phase == .stopped && stopped.challenge == nil && stopped.token == nil)

        let next = harness.start(run: UUID())
        await harness.reach(.phase(.awaitingProfile))
        #expect(await harness.send(.authenticate(run: harness.run, challenge: challenge.id, assertion: Data([65]))) == .rejected(.staleRequest))
        await harness.session.stop()
        await #expect(throws: ClientVPNLiveFailure.cancelled) { try await next.value }
        #expect(harness.engines.cancellations.isEmpty)
    }

    @Test func cachedTokenConnectsAndTheTunnelDropIsReported() async throws {
        var harness = Harness()
        let token = ClientVPNLiveToken(username: Data([65]), token: Data([66]))
        let startup = harness.start()
        await harness.reach(.phase(.awaitingProfile))
        _ = await harness.send(.connect(run: harness.run, profile: "client", token: token))
        let engine = try harness.engines.latest()
        guard case .token(let supplied) = engine.credentials else { Issue.record("The attempt had no cached token"); return }
        #expect(supplied == token)
        let tunnel = ClientVPNTunnelSettings(addresses: ["10.0.12.4/27"], routes: ["10.0.0.0/16"], dnsServers: ["10.0.0.2"])
        engine.apply(tunnel)
        #expect(try await harness.snapshot().tunnel == nil)

        engine.send(.connected)
        engine.send(.token(token))
        try await startup.value
        await harness.reach(.tokenIssued)
        let running = try await harness.snapshot()
        #expect(running.token == token && running.packets == ClientVPNPacketCounts(sent: 4, received: 3) && running.tunnel == tunnel)
        #expect(await harness.session.handle(.status(run: UUID())) == .rejected(.staleRequest))

        engine.send(.stopped(.transport))
        await harness.reach(.phase(.failed))
        let failed = try await harness.snapshot()
        #expect(failed.token == nil && failed.failure == .transport && failed.packets == ClientVPNPacketCounts(sent: 4, received: 3) && failed.tunnel == nil)
        #expect(harness.engines.cancellations == [.transport])
    }

    @Test func appRequestedStopIsReportedToTheSystem() async throws {
        var harness = Harness()
        let startup = harness.start()
        await harness.reach(.phase(.awaitingProfile))
        _ = await harness.send(.connect(run: harness.run, profile: "client", token: nil))
        let engine = try harness.engines.latest()
        engine.send(.connected)
        try await startup.value

        guard case .snapshot(let stopping) = await harness.send(.stop(run: harness.run)) else { Issue.record("Stop was rejected"); return }
        #expect(stopping.phase == .stopping && engine.stops == 1)
        engine.send(.stopped(nil))
        await harness.reach(.phase(.stopped))
        #expect(harness.engines.cancellations == [.cancelled])
        // The system's own stop then finds nothing left to do.
        await harness.session.stop()
    }

    @Test func profileWaitTimesOut() async throws {
        let harness = Harness()
        let startup = harness.start()
        await harness.clock.sleeperArrived()
        harness.clock.advance(by: .seconds(29))
        #expect(try await harness.snapshot().phase == .awaitingProfile)
        harness.clock.advance(by: .seconds(1))
        await #expect(throws: ClientVPNLiveFailure.timedOut) { try await startup.value }
        #expect(try await harness.snapshot().phase == .failed)
        #expect(harness.engines.cancellations.isEmpty)
    }

    @Test func connectionTimeoutWaitsForTheEngineToStop() async throws {
        var harness = Harness()
        let startup = harness.start()
        await harness.reach(.phase(.awaitingProfile))
        _ = await harness.send(.connect(run: harness.run, profile: "client", token: nil))
        let engine = try harness.engines.latest()
        await harness.clock.sleeperArrived()
        harness.clock.advance(by: .seconds(75))
        await harness.reach(.phase(.stopping))
        #expect(engine.stops == 1)
        engine.send(.stopped(.cancelled))
        await #expect(throws: ClientVPNLiveFailure.timedOut) { try await startup.value }
    }

    @Test func browserSignInTimesOutAfterTenMinutes() async throws {
        var harness = Harness()
        let startup = harness.start()
        await harness.reach(.phase(.awaitingProfile))
        _ = await harness.send(.connect(run: harness.run, profile: "client", token: nil))
        try harness.engines.latest().send(.challenge(url: Self.signInURL, cookie: Self.cookie))
        await harness.reach(.phase(.authenticating))
        await harness.clock.sleeperArrived()
        harness.clock.advance(by: .seconds(599))
        #expect(try await harness.snapshot().phase == .authenticating)
        harness.clock.advance(by: .seconds(1))
        await #expect(throws: ClientVPNLiveFailure.timedOut) { try await startup.value }
        #expect(try await harness.snapshot().challenge == nil)
    }

    @Test func requestsOutOfTurnAreRejected() async throws {
        var harness = Harness()
        let startup = harness.start()
        await harness.reach(.phase(.awaitingProfile))
        await #expect(throws: ClientVPNLiveFailure.busy) { try await harness.start(run: UUID()).value }
        #expect(await harness.send(.connect(run: harness.run, profile: "", token: nil)) == .rejected(.invalidProfile))
        #expect(await harness.send(.authenticate(run: harness.run, challenge: UUID(), assertion: Data([65]))) == .rejected(.staleRequest))
        _ = await harness.send(.connect(run: harness.run, profile: "client", token: nil))
        #expect(await harness.send(.connect(run: harness.run, profile: "client", token: nil)) == .rejected(.busy))
        #expect(await harness.send(.status(run: UUID())) == .rejected(.staleRequest))
        #expect(harness.engines.count == 1)
        let stopping = Task { [session = harness.session] in await session.stop() }
        await harness.reach(.phase(.stopping))
        try harness.engines.latest().send(.stopped(.cancelled))
        await stopping.value
        await #expect(throws: ClientVPNLiveFailure.cancelled) { try await startup.value }
    }

    @Test(arguments: [
        (URL(string: "http://signin.example.invalid/")!, cookie),
        (URL(string: "https://user:password@signin.example.invalid/")!, cookie),
        (URL(string: "https://signin.example.invalid/#fragment")!, cookie),
        (signInURL, Data()),
        (signInURL, Data(count: ClientVPNLimits.challengeCookieBytes + 1)),
    ])
    func unsafeChallengesFailTheSignIn(url: URL, cookie: Data) async throws {
        var harness = Harness()
        let startup = harness.start()
        await harness.reach(.phase(.awaitingProfile))
        _ = await harness.send(.connect(run: harness.run, profile: "client", token: nil))
        try harness.engines.latest().send(.challenge(url: url, cookie: cookie))
        await #expect(throws: ClientVPNLiveFailure.authentication) { try await startup.value }
        #expect(try await harness.snapshot().challenge == nil)
    }

    @Test func missingTunnelFailsTheAttempt() async throws {
        var harness = Harness(enginesAvailable: false)
        let startup = harness.start()
        await harness.reach(.phase(.awaitingProfile))
        guard case .snapshot(let failed) = await harness.send(.connect(run: harness.run, profile: "client", token: nil)) else { Issue.record("Connect was rejected"); return }
        #expect(failed.phase == .failed && failed.failure == .transport)
        await #expect(throws: ClientVPNLiveFailure.transport) { try await startup.value }
    }
}

/// A session on a manual clock, with fake engines, observed through its activity.
private struct Harness {
    let run = UUID()
    let clock = ManualClock()
    let session: ClientVPNLiveSession
    let engines: EngineLog
    private var activity: AsyncStream<ClientVPNLiveActivity>.Iterator

    init(enginesAvailable: Bool = true) {
        session = ClientVPNLiveSession(clock: clock)
        engines = EngineLog(available: enginesAvailable)
        activity = session.activity.makeAsyncIterator()
    }

    func start(run: UUID? = nil) -> Task<Void, any Error> {
        let session = session, run = run ?? self.run, engines = engines
        return Task { try await session.start(run: run, makeEngine: { engines.make($0) }, cancelTunnel: { engines.cancelled($0) }) }
    }

    func send(_ request: ClientVPNLiveRequest) async -> ClientVPNLiveResponse {
        await session.handle(request)
    }

    func snapshot() async throws -> ClientVPNLiveSnapshot {
        guard case .snapshot(let snapshot) = await session.handle(.status(run: run)) else { throw ClientVPNLiveFailure.staleRequest }
        return snapshot
    }

    /// Waits for the session to report `expected`, skipping earlier activity.
    mutating func reach(_ expected: ClientVPNLiveActivity, sourceLocation: SourceLocation = #_sourceLocation) async {
        while let next = await activity.next() {
            if next == expected { return }
        }
        Issue.record("The session stopped reporting before \(expected)", sourceLocation: sourceLocation)
    }
}

private final class EngineLog: Sendable {
    private struct State {
        var engines: [FakeEngine] = []
        var cancellations: [ClientVPNLiveFailure] = []
    }

    private let available: Bool
    private let state = Mutex(State())

    init(available: Bool) {
        self.available = available
    }

    var count: Int { state.withLock { $0.engines.count } }
    var cancellations: [ClientVPNLiveFailure] { state.withLock { $0.cancellations } }

    func make(_ events: @escaping @Sendable (ClientVPNEngineEvent) -> Void) -> (any ClientVPNLiveEngine)? {
        guard available else { return nil }
        let engine = FakeEngine(events: events)
        state.withLock { $0.engines.append(engine) }
        return engine
    }

    func latest() throws -> FakeEngine {
        try #require(state.withLock { $0.engines.last })
    }

    func cancelled(_ failure: ClientVPNLiveFailure) {
        state.withLock { $0.cancellations.append(failure) }
    }
}

private final class FakeEngine: ClientVPNLiveEngine {
    private struct State {
        var credentials: ClientVPNEngineCredentials?
        var stops = 0
        var tunnel: ClientVPNTunnelSettings?
    }

    private let events: @Sendable (ClientVPNEngineEvent) -> Void
    private let state = Mutex(State())

    init(events: @escaping @Sendable (ClientVPNEngineEvent) -> Void) {
        self.events = events
    }

    var credentials: ClientVPNEngineCredentials? { state.withLock { $0.credentials } }
    var stops: Int { state.withLock { $0.stops } }

    func start(profile: String, credentials: ClientVPNEngineCredentials?) { state.withLock { $0.credentials = credentials } }
    func stop() { state.withLock { $0.stops += 1 } }
    func packetCounts() -> ClientVPNPacketCounts { ClientVPNPacketCounts(sent: 4, received: 3) }
    func tunnelSettings() -> ClientVPNTunnelSettings? { state.withLock { $0.tunnel } }
    func apply(_ tunnel: ClientVPNTunnelSettings) { state.withLock { $0.tunnel = tunnel } }
    func send(_ event: ClientVPNEngineEvent) { events(event) }
}
