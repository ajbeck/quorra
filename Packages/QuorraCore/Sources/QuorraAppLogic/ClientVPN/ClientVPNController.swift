import ClientVPN
import Foundation
import Observation

/// Connects one Client VPN profile at a time: starts the tunnel, sends the profile, answers the
/// browser sign-in and follows the tunnel until it stops.
///
/// The tunnel can't message the app first, so the controller asks for status while connecting or
/// signing in. Once connected it relies on the system's status changes.
@MainActor
@Observable
public final class ClientVPNController {
    public enum State: Hashable, Sendable {
        case disconnected, connecting, signingIn, connected, disconnecting
        case failed(ClientVPNLiveFailure)
    }

    public private(set) var state = State.disconnected
    /// The saved profile the state describes: the one connected, or the last one tried.
    public private(set) var profileID: UUID?
    public private(set) var packets = ClientVPNPacketCounts()
    /// The tunnel's addresses, routes and DNS servers while connected.
    public private(set) var tunnel: ClientVPNTunnelSettings?
    public private(set) var connectedDate: Date?
    /// The last session token, held in memory only, for the saved profile and profile text it came from.
    private var token: (profileID: UUID, profile: String, signedIn: Date, value: ClientVPNLiveToken)?

    @ObservationIgnored private let transport: any ClientVPNTransport
    @ObservationIgnored private let signIn: any ClientVPNSignIn
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var run: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(transport: any ClientVPNTransport, signIn: any ClientVPNSignIn, clock: any Clock<Duration> = ContinuousClock()) {
        self.transport = transport
        self.signIn = signIn
        self.clock = clock
    }

    public var isActive: Bool {
        switch state {
        case .connecting, .signingIn, .connected, .disconnecting: true
        case .disconnected, .failed: false
        }
    }

    /// When the browser sign-in behind a saved session token for `profileID` happened, if one is held.
    public func savedSignIn(for profileID: UUID) -> Date? {
        token?.profileID == profileID ? token?.signedIn : nil
    }

    /// Drops the session token, for example when the profile's endpoint or file changes.
    public func forgetSignIn(for profileID: UUID) {
        if token?.profileID == profileID { token = nil }
    }

    /// Connects `profile`, the `.ovpn` text of the saved profile `profileID`. A session token from this
    /// profile's text is reused unless `signInAgain`; if the server refuses it, the browser sign-in runs.
    /// `profileName` is only shown on the browser's sign-in page.
    public func connect(profileID: UUID, profileName: String, profile: String, signInAgain: Bool = false) {
        guard !isActive else { return }
        if signInAgain { forgetSignIn(for: profileID) }
        let cached = token?.profileID == profileID && token?.profile == profile ? token?.value : nil
        let run = UUID()
        self.run = run
        self.profileID = profileID
        state = .connecting
        packets = ClientVPNPacketCounts()
        tunnel = nil
        connectedDate = nil
        task = Task {
            await drive(run: run, profileID: profileID, profileName: profileName, profile: profile, token: cached)
        }
    }

    /// Connects `profileID` unless it is already connected or connecting, and returns once the tunnel
    /// is up. Throws the failure if it stops instead, `.cancelled` if it is disconnected first, and
    /// `.busy` if another profile holds the tunnel.
    public func connectAndWait(profileID: UUID, profileName: String, profile: String) async throws {
        if isActive, self.profileID != profileID { throw ClientVPNLiveFailure.busy }
        if !isActive { connect(profileID: profileID, profileName: profileName, profile: profile) }
        for await state in Observations({ (self.profileID, self.state) }) {
            guard state.0 == profileID else { throw ClientVPNLiveFailure.cancelled }
            switch state.1 {
            case .connected: return
            case .failed(let failure): throw failure
            case .disconnected: throw ClientVPNLiveFailure.cancelled
            case .connecting, .signingIn, .disconnecting: continue
            }
        }
        throw CancellationError()
    }

    /// Stops the tunnel, or clears a failure the tunnel already stopped with.
    public func disconnect() async {
        if case .failed = state {
            state = .disconnected
            return
        }
        guard isActive else { return }
        run = nil
        task?.cancel()
        task = nil
        state = .disconnecting
        await transport.stop()
        tunnel = nil
        state = .disconnected
    }

    private func drive(run: UUID, profileID: UUID, profileName: String, profile: String, token: ClientVPNLiveToken?) async {
        do {
            try await transport.start(run: run)
            try await sendProfile(run: run, profile: profile, token: token)
            try await follow(run: run, profileID: profileID, profileName: profileName, profile: profile)
        } catch {
            guard self.run == run else { return }
            let failure = error as? ClientVPNLiveFailure ?? .transport
            // A token that didn't connect is spent; one that connected stays for reconnecting after a drop.
            if let token, state != .connected, self.token?.value == token { self.token = nil }
            await transport.stop()
            guard self.run == run else { return }
            self.run = nil
            tunnel = nil
            state = failure == .cancelled ? .disconnected : .failed(failure)
        }
    }

    /// The system reports connecting before the provider's `startTunnel` runs, so the first message
    /// can find no run yet. Retry for up to 20 seconds while the tunnel is still connecting.
    private func sendProfile(run: UUID, profile: String, token: ClientVPNLiveToken?) async throws {
        for attempt in 1... {
            do {
                _ = try await snapshot(.connect(run: run, profile: profile, token: token))
                return
            } catch {
                let failure = error as? ClientVPNLiveFailure
                guard failure == nil || failure == .staleRequest || failure == .transport,
                      attempt < 80, transport.status == .connecting else { throw error }
            }
            try await clock.sleep(for: .milliseconds(250))
        }
    }

    private func follow(run: UUID, profileID: UUID, profileName: String, profile: String) async throws {
        var answered = Set<UUID>()
        var settlingPolls = 0
        while true {
            let snapshot = try await self.snapshot(.status(run: run))
            guard self.run == run else { throw CancellationError() }
            packets = snapshot.packets
            tunnel = snapshot.tunnel
            if let value = snapshot.token, token?.value != value {
                // A token renewed on a token run keeps the time of the browser sign-in behind it.
                let renewed = token?.profileID == profileID && token?.profile == profile
                token = (profileID, profile, renewed ? token?.signedIn ?? Date() : Date(), value)
            }
            switch snapshot.phase {
            case .awaitingProfile, .connecting:
                state = .connecting
            case .authenticating:
                guard let challenge = snapshot.challenge, answered.insert(challenge.id).inserted else {
                    throw ClientVPNLiveFailure.authentication
                }
                // A token run that asks for the browser means the server refused the token.
                if token?.profileID == profileID { token = nil }
                state = .signingIn
                let assertion = try await signInWhileTunnelRuns(challenge, profileName: profileName)
                _ = try await self.snapshot(.authenticate(run: run, challenge: challenge.id, assertion: assertion))
                state = .connecting
                continue
            case .running:
                if state != .connected { connectedDate = transport.connectedDate ?? Date() }
                state = .connected
                // The core issues its token and applies its settings just after connecting; look a few
                // more times so neither is missed, then wait for the system to report the tunnel down.
                if snapshot.token == nil || snapshot.tunnel == nil, settlingPolls < 10 {
                    settlingPolls += 1
                } else {
                    try await tunnelStopped()
                }
            case .stopped, .stopping, .failed:
                throw snapshot.failure ?? ClientVPNLiveFailure.transport
            }
            try await clock.sleep(for: .seconds(1))
        }
    }

    private func snapshot(_ request: ClientVPNLiveRequest) async throws -> ClientVPNLiveSnapshot {
        switch try await transport.send(request) {
        case .snapshot(let snapshot):
            guard snapshot.run == request.run else { throw ClientVPNLiveFailure.staleRequest }
            return snapshot
        case .rejected(let failure):
            throw failure
        }
    }

    /// Runs the browser sign-in, abandoning it if the tunnel stops first (for example when the
    /// provider's ten-minute sign-in timeout ends the run).
    private func signInWhileTunnelRuns(_ challenge: ClientVPNBrowserChallenge, profileName: String) async throws -> Data {
        let signIn = signIn, transport = transport
        let attempt = Task { try await signIn.assertion(for: challenge, profileName: profileName) }
        let watcher = Task {
            await Self.disconnection(of: transport)
            attempt.cancel()
        }
        defer { watcher.cancel() }
        do {
            return try await withTaskCancellationHandler {
                try await attempt.value
            } onCancel: {
                attempt.cancel()
            }
        } catch is CancellationError where !Task.isCancelled {
            // The watcher cancelled the sign-in because the tunnel stopped.
            throw await transport.lastFailure() ?? ClientVPNLiveFailure.transport
        }
    }

    private func tunnelStopped() async throws -> Never {
        await Self.disconnection(of: transport)
        try Task.checkCancellation()
        throw await transport.lastFailure() ?? ClientVPNLiveFailure.transport
    }

    private static func disconnection(of transport: any ClientVPNTransport) async {
        let changes = transport.statusChanges()
        guard transport.status != .disconnected else { return }
        for await status in changes where status == .disconnected {
            return
        }
    }
}
