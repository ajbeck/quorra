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
    public enum State: Equatable, Sendable {
        case disconnected, connecting, signingIn, connected, disconnecting
        case failed(ClientVPNLiveFailure)
    }

    public private(set) var state = State.disconnected
    public private(set) var packets = ClientVPNPacketCounts()
    /// The last session token, held in memory only and only for the profile text it came from.
    private var token: (profile: String, value: ClientVPNLiveToken)?

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

    /// Whether `profile` can reconnect with the last session token instead of the browser.
    public func hasSessionToken(for profile: String) -> Bool {
        token?.profile == profile
    }

    /// `profileName` is only shown on the browser's sign-in page.
    public func connect(profileName: String, profile: String, usingSessionToken: Bool = false) {
        guard !isActive else { return }
        let cached = usingSessionToken && token?.profile == profile ? token?.value : nil
        guard !usingSessionToken || cached != nil else {
            state = .failed(.authentication)
            return
        }
        let run = UUID()
        self.run = run
        state = .connecting
        packets = ClientVPNPacketCounts()
        task = Task {
            await drive(run: run, profileName: profileName, profile: profile, token: cached)
        }
    }

    public func disconnect() async {
        guard isActive else { return }
        run = nil
        task?.cancel()
        task = nil
        state = .disconnecting
        await transport.stop()
        state = .disconnected
    }

    private func drive(run: UUID, profileName: String, profile: String, token: ClientVPNLiveToken?) async {
        do {
            try await transport.start(run: run)
            try await sendProfile(run: run, profile: profile, token: token)
            try await follow(run: run, profileName: profileName, profile: profile, usingToken: token != nil)
        } catch {
            guard self.run == run else { return }
            let failure = error as? ClientVPNLiveFailure ?? .transport
            // A token that didn't connect is spent.
            if token != nil { self.token = nil }
            await transport.stop()
            guard self.run == run else { return }
            self.run = nil
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

    private func follow(run: UUID, profileName: String, profile: String, usingToken: Bool) async throws {
        var answered = Set<UUID>()
        var tokenPolls = 0
        while true {
            let snapshot = try await self.snapshot(.status(run: run))
            guard self.run == run else { throw CancellationError() }
            packets = snapshot.packets
            if let value = snapshot.token { token = (profile, value) }
            switch snapshot.phase {
            case .awaitingProfile, .connecting:
                state = .connecting
            case .authenticating:
                // A token run that asks for the browser means the token was refused.
                guard !usingToken, let challenge = snapshot.challenge, answered.insert(challenge.id).inserted else {
                    throw ClientVPNLiveFailure.authentication
                }
                state = .signingIn
                let assertion = try await signInWhileTunnelRuns(challenge, profileName: profileName)
                _ = try await self.snapshot(.authenticate(run: run, challenge: challenge.id, assertion: assertion))
                state = .connecting
                continue
            case .running:
                state = .connected
                // The core issues its token just after connecting; look a few more times so it isn't missed.
                if snapshot.token == nil, tokenPolls < 10 {
                    tokenPolls += 1
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
