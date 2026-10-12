import Foundation

public enum ClientVPNEngineCredentials: Sendable {
    case assertion(cookie: Data, response: Data)
    case token(ClientVPNLiveToken)
}

public enum ClientVPNEngineEvent: Sendable {
    case connected
    case challenge(url: URL, cookie: Data)
    case token(ClientVPNLiveToken)
    case stopped(ClientVPNLiveFailure?)
}

/// What the session reports as it runs, for logging and tests. Carries no secrets.
public enum ClientVPNLiveActivity: Equatable, Sendable {
    case phase(ClientVPNLivePhase)
    case tokenIssued
}

/// One OpenVPN connection attempt. A challenge or a stop ends the attempt.
public protocol ClientVPNLiveEngine: AnyObject, Sendable {
    func start(profile: String, credentials: ClientVPNEngineCredentials?)
    func stop()
    func packetCounts() -> ClientVPNPacketCounts
    /// The network settings this attempt last applied, if any.
    func tunnelSettings() -> ClientVPNTunnelSettings?
}

public struct ClientVPNLiveTimeouts: Sendable {
    public var profile: Duration
    public var connection: Duration
    public var authentication: Duration

    public init(profile: Duration = .seconds(30), connection: Duration = .seconds(75), authentication: Duration = .seconds(600)) {
        self.profile = profile
        self.connection = connection
        self.authentication = authentication
    }
}

/// Runs one VPN connection for the packet tunnel, from the app's start through browser sign-in to stop.
///
/// A run spans attempts: the first attempt usually ends in a browser challenge, and the app's reply
/// starts an authenticated attempt. Run, attempt and challenge IDs reject replies and callbacks that
/// arrive after the state they belonged to has moved on.
public actor ClientVPNLiveSession {
    /// Makes an engine for one attempt, or nil when the tunnel is gone. The engine reports through `events`.
    public typealias EngineFactory = @Sendable (_ events: @escaping @Sendable (ClientVPNEngineEvent) -> Void) -> (any ClientVPNLiveEngine)?

    private struct Challenge {
        let id: UUID
        let url: URL
        let cookie: Data
    }

    public nonisolated let activity: AsyncStream<ClientVPNLiveActivity>
    private let activityContinuation: AsyncStream<ClientVPNLiveActivity>.Continuation
    private let timeouts: ClientVPNLiveTimeouts
    private let clock: any Clock<Duration>

    private var makeEngine: EngineFactory?
    private var cancelTunnel: (@Sendable (ClientVPNLiveFailure) -> Void)?
    private var run: UUID?
    private var phase = ClientVPNLivePhase.stopped {
        didSet { if phase != oldValue { activityContinuation.yield(.phase(phase)) } }
    }
    private var failure: ClientVPNLiveFailure?
    private var profile: String?
    private var challenge: Challenge?
    private var token: ClientVPNLiveToken?
    private var engine: (any ClientVPNLiveEngine)?
    private var attempt: UUID?
    private var finalPackets = ClientVPNPacketCounts()
    private var deadline: Task<Void, Never>?
    private var events: Task<Void, Never>?
    private var startup: CheckedContinuation<Void, any Error>?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    public init(timeouts: ClientVPNLiveTimeouts = .init(), clock: any Clock<Duration> = ContinuousClock()) {
        self.timeouts = timeouts
        self.clock = clock
        (activity, activityContinuation) = AsyncStream.makeStream()
    }

    deinit {
        activityContinuation.finish()
    }

    /// Starts a run and returns once the tunnel connects. The app sends the profile with `handle(_:)` meanwhile.
    /// `cancelTunnel` reports a stop that the system didn't ask for.
    public func start(run: UUID, makeEngine: @escaping EngineFactory, cancelTunnel: @escaping @Sendable (ClientVPNLiveFailure) -> Void) async throws {
        guard phase == .stopped || phase == .failed else { throw ClientVPNLiveFailure.busy }
        self.run = run
        self.makeEngine = makeEngine
        self.cancelTunnel = cancelTunnel
        failure = nil
        finalPackets = .init()
        phase = .awaitingProfile
        armDeadline(timeouts.profile)
        try await withCheckedThrowingContinuation { startup = $0 }
    }

    public func handle(_ request: ClientVPNLiveRequest) -> ClientVPNLiveResponse {
        guard let run, request.run == run else { return .rejected(.staleRequest) }
        switch request {
        case .status:
            break
        case .stop:
            beginStopping()
        case .connect(_, let profile, let token):
            guard phase == .awaitingProfile else { return .rejected(.busy) }
            guard !profile.isEmpty, profile.utf8.count <= ClientVPNLimits.profileBytes else { return .rejected(.invalidProfile) }
            self.profile = profile
            startAttempt(run: run, credentials: token.map(ClientVPNEngineCredentials.token))
        case .authenticate(_, let id, let assertion):
            guard phase == .authenticating, let challenge, challenge.id == id else { return .rejected(.staleRequest) }
            guard !assertion.isEmpty, assertion.count + challenge.cookie.count <= ClientVPNLimits.credentialBytes else { return .rejected(.invalidCredentials) }
            self.challenge = nil
            startAttempt(run: run, credentials: .assertion(cookie: challenge.cookie, response: assertion))
        }
        return .snapshot(snapshot(run: run))
    }

    /// Stops the run and returns once the engine has stopped.
    public func stop() async {
        guard phase != .stopped, phase != .failed else {
            clearSecrets()
            return
        }
        await withCheckedContinuation { continuation in
            stopWaiters.append(continuation)
            beginStopping()
        }
    }

    private func beginStopping() {
        switch phase {
        case .stopping:
            return
        case .stopped, .failed:
            clearSecrets()
            return
        case .awaitingProfile, .connecting, .authenticating, .running:
            break
        }
        if failure == nil { failure = .cancelled }
        phase = .stopping
        deadline?.cancel()
        deadline = nil
        profile = nil
        challenge = nil
        token = nil
        if let engine { engine.stop() } else { stopped() }
    }

    private func startAttempt(run: UUID, credentials: ClientVPNEngineCredentials?) {
        guard let profile, let makeEngine else { return }
        let attempt = UUID()
        let (stream, continuation) = AsyncStream<ClientVPNEngineEvent>.makeStream()
        let engine = makeEngine { event in
            continuation.yield(event)
            switch event {
            case .challenge, .stopped: continuation.finish()
            case .connected, .token: break
            }
        }
        guard let engine else {
            failure = .transport
            stopped()
            return
        }
        phase = .connecting
        self.attempt = attempt
        self.engine = engine
        events?.cancel()
        // One stream per attempt keeps the engine's callback order, such as a token after connecting.
        events = Task { [weak self] in
            for await event in stream {
                await self?.received(event, run: run, attempt: attempt)
            }
        }
        armDeadline(timeouts.connection)
        engine.start(profile: profile, credentials: credentials)
    }

    private func received(_ event: ClientVPNEngineEvent, run: UUID, attempt: UUID) {
        guard self.run == run, self.attempt == attempt else { return }
        switch event {
        case .connected:
            guard phase == .connecting else { return }
            phase = .running
            deadline?.cancel()
            deadline = nil
            startup?.resume()
            startup = nil
        case .token(let token):
            guard phase == .running, token.isWithinLimits else { return }
            self.token = token
            activityContinuation.yield(.tokenIssued)
        case .challenge(let url, let cookie):
            endAttempt()
            guard phase == .connecting else {
                stopped()
                return
            }
            guard Self.isSignInURL(url), !cookie.isEmpty, cookie.count <= ClientVPNLimits.challengeCookieBytes else {
                failure = .authentication
                stopped()
                return
            }
            challenge = Challenge(id: UUID(), url: url, cookie: cookie)
            phase = .authenticating
            armDeadline(timeouts.authentication)
        case .stopped(let reason):
            endAttempt()
            if failure == nil { failure = reason ?? .transport }
            stopped()
        }
    }

    private func endAttempt() {
        finalPackets = engine?.packetCounts() ?? finalPackets
        engine = nil
        attempt = nil
    }

    /// Ends the run: fails a pending start, releases `stop()` callers, and tells the system about a stop it didn't ask for.
    private func stopped() {
        let failure = self.failure ?? .transport
        self.failure = failure
        // With no pending start the tunnel was up, and with no stop waiters the system didn't ask for this stop.
        let reportToSystem = startup == nil && stopWaiters.isEmpty
        endAttempt()
        clearSecrets()
        phase = failure == .cancelled ? .stopped : .failed
        startup?.resume(throwing: failure)
        startup = nil
        let waiters = stopWaiters
        stopWaiters = []
        for waiter in waiters { waiter.resume() }
        if reportToSystem { cancelTunnel?(failure) }
    }

    private func clearSecrets() {
        deadline?.cancel()
        deadline = nil
        events?.cancel()
        events = nil
        profile = nil
        challenge = nil
        token = nil
    }

    private func snapshot(run: UUID) -> ClientVPNLiveSnapshot {
        ClientVPNLiveSnapshot(
            run: run,
            phase: phase,
            challenge: challenge.map { ClientVPNBrowserChallenge(id: $0.id, url: $0.url) },
            token: token,
            failure: failure,
            packets: engine?.packetCounts() ?? finalPackets,
            tunnel: phase == .running ? engine?.tunnelSettings() : nil
        )
    }

    private func armDeadline(_ duration: Duration) {
        deadline?.cancel()
        let run = run, attempt = attempt, phase = phase, clock = clock
        deadline = Task { [weak self] in
            do { try await clock.sleep(for: duration) } catch { return }
            await self?.expire(run: run, attempt: attempt, phase: phase)
        }
    }

    private func expire(run: UUID?, attempt: UUID?, phase: ClientVPNLivePhase) {
        guard self.run == run, self.attempt == attempt, self.phase == phase else { return }
        failure = .timedOut
        beginStopping()
    }

    /// A challenge URL the app may open: HTTPS with a host, and no credentials or fragment.
    private static func isSignInURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil && url.fragment == nil
    }
}
