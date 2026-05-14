import Foundation
import OSLog

private let logger = Logger(subsystem: "dev.ajbeck.quorra", category: "IAMIdentityCenter")

/// Actor orchestrating IAM Identity Center sign-in flows.
///
/// Owns OIDC client caching, device-grant polling, token persistence, expiration scheduling,
/// and the `events` stream. Each sign-in operation runs in its own Task; cancellation is
/// cooperative via `cancelSignIn(sessionName:)`.
public actor IdentityCenterService: IdentityCenterServicing {
    internal let keychain: any KeychainStore
    internal let oidcClient: any OIDCRequesting
    internal let sleeper: any Sleeper
    /// URLSession for Portal /logout calls. Injectable for tests.
    internal let urlSession: URLSession

    /// Map of in-flight sign-in tasks keyed by session name.
    private var inFlight: [String: Task<StoredSSOToken, Error>] = [:]

    /// Expiration timers keyed by session name (D8 / D11).
    var expirationTimers: [String: Task<Void, Never>] = [:]

    /// Refresh timers keyed by session name — fires at `expiresAt − refreshSkew` (D11 / A2).
    var refreshTimers: [String: Task<Void, Never>] = [:]

    /// In-flight refresh tasks keyed by session name. Single-flight coalescing (D12 / A2).
    var inFlightRefresh: [String: Task<StoredSSOToken, Error>] = [:]

    /// Per-session Task chain for async serialization (D21 / A2).
    var sessionLocks: [String: Task<Void, Never>] = [:]

    /// Service constants (Keychain service attributes + timing constants).
    enum ServiceConstants {
        static let oidcClientService = "dev.ajbeck.quorra.oidc-client"
        static let ssoTokenService = "dev.ajbeck.quorra.sso-token"
        static let oidcClientReregistrationLeadTime: TimeInterval = 7 * 24 * 60 * 60
        static let slowDownIncrementSeconds: TimeInterval = 5
        /// Refresh skew: trigger refresh this many seconds before `expiresAt` (D11 / D12).
        /// Matches the AWS SDKs' SSO credential provider skew so Quorra's behavior is
        /// consistent with `aws` CLI on the same machine.
        static let refreshSkew: TimeInterval = 5 * 60
    }

    // MARK: - Events stream (D2)

    /// Shared stream of auth events. Single-consumer per protocol contract.
    ///
    /// `nonisolated` because the stream is created at init time and stored as a `let`.
    /// Apple: Swift/AsyncStream/makeStream(of:bufferingPolicy:)
    public nonisolated let events: AsyncStream<AuthEvent>

    /// Continuation used to yield events from within the actor's isolated context.
    /// Apple: Swift/AsyncStream/Continuation — "supports escaping", thread-safe.
    let eventContinuation: AsyncStream<AuthEvent>.Continuation

    // MARK: - Init

    /// Creates a service instance.
    ///
    /// - Parameters:
    ///   - keychain: Keychain store for persisting secrets (production: `Keychain`; tests: an in-memory stub)
    ///   - oidcClient: Pre-configured OIDC client for the region
    ///   - sleeper: Time source for sleep/timeout (injectable for testing)
    public init(
        keychain: any KeychainStore,
        oidcClient: any OIDCRequesting,
        sleeper: any Sleeper = WallClockSleeper(),
        urlSession: URLSession = .shared
    ) {
        self.keychain = keychain
        self.oidcClient = oidcClient
        self.sleeper = sleeper
        self.urlSession = urlSession
        // Bounded buffer guards against producer outrunning a slow consumer (rare in
        // practice — events fire on user gestures and one-shot timers — but the cap is
        // self-documenting and prevents pathological growth in test loops / A2 refresh storms).
        let (stream, continuation) = AsyncStream<AuthEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        self.events = stream
        self.eventContinuation = continuation
    }

    // MARK: - Public API

    /// Drives the full device-grant sign-in flow.
    ///
    /// Reuses a cached OIDC client from Keychain when present and not near-expiry; otherwise calls
    /// `RegisterClient` first. Calls `StartDeviceAuthorization`, invokes `verificationHandler` once
    /// with the resulting `DeviceVerification`, then polls `CreateToken` every `interval` seconds until
    /// the user completes the browser step or the device code expires. Persists the token to Keychain
    /// and returns it.
    ///
    /// Emits `.signInStarted`, then one of `.signedIn` / `.signInCancelled` / `.signInFailed` (D2).
    ///
    /// - Parameters:
    ///   - sessionName: SSO session name (from `~/.aws/config` `[sso-session NAME]`)
    ///   - startUrl: Identity Center start URL
    ///   - region: AWS region (e.g. "us-east-1")
    ///   - scopes: OIDC scopes (must include "sso:account:access" for refresh token issuance)
    ///   - clientName: Human-readable client name (default: "Quorra")
    ///   - verificationHandler: Async callback invoked once with verification info for the UI
    /// - Returns: Stored SSO token
    /// - Throws: `.invalidClient`, `.expiredDeviceCode`, `.accessDenied`, `.deviceFlowTimedOut`, `.signInAlreadyInProgress`, `.userCancelled`, or transport errors
    public func signIn(
        sessionName: String,
        startUrl: URL,
        region: String,
        scopes: [String],
        clientName: String = "Quorra",
        verificationHandler: @escaping @Sendable (DeviceVerification) async -> Void
    ) async throws -> StoredSSOToken {
        if inFlight[sessionName] != nil {
            throw IAMIdentityCenterError.signInAlreadyInProgress(sessionName: sessionName)
        }

        // D21 cancel-then-queue: cancel any in-flight refresh before taking the session lock
        // so its network call unwinds quickly and the lock becomes available without delay.
        inFlightRefresh[sessionName]?.cancel()
        cancelRefresh(forSession: sessionName)

        eventContinuation.yield(.signInStarted(sessionName: sessionName))

        // D21: take the session lock around runSignIn so a concurrent refresh or signOut
        // cannot interleave at actor suspension points. The cancel-then-queue lines above
        // ensure the lock becomes available quickly by cancelling any in-flight refresh.
        let task = Task<StoredSSOToken, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.withSessionLock(sessionName) {
                try await self.runSignIn(
                    sessionName: sessionName,
                    startUrl: startUrl,
                    region: region,
                    scopes: scopes,
                    clientName: clientName,
                    verificationHandler: verificationHandler
                )
            }
        }
        inFlight[sessionName] = task

        defer { inFlight[sessionName] = nil }

        do {
            let token = try await task.value
            // Clear any sign-out advisory flag by re-using the same session name on success
            eventContinuation.yield(.signedIn(sessionName: sessionName))
            // D11: schedule both T_expire and T_refresh on successful sign-in
            scheduleExpiration(forSession: sessionName, expiresAt: token.expiresAt)
            if token.refreshToken != nil {
                scheduleRefresh(forSession: sessionName, expiresAt: token.expiresAt)
            }
            return token
        } catch is CancellationError {
            eventContinuation.yield(.signInCancelled(sessionName: sessionName))
            throw IAMIdentityCenterError.userCancelled
        } catch {
            eventContinuation.yield(.signInFailed(sessionName: sessionName))
            throw error
        }
    }

    /// Cancels an in-flight sign-in for the given session.
    ///
    /// The `signIn` call will throw `.userCancelled`. If no sign-in is in progress, this is a no-op.
    ///
    /// - Parameter sessionName: SSO session name
    public func cancelSignIn(sessionName: String) {
        inFlight[sessionName]?.cancel()
    }

    // MARK: - Internal helpers for extensions

    /// Returns the in-flight task for the session if any.
    func inFlightTask(for sessionName: String) -> Task<StoredSSOToken, Error>? {
        inFlight[sessionName]
    }

    // MARK: - Private

    /// Body of the sign-in flow — extracted so the public `signIn` can manage task lifecycle.
    private func runSignIn(
        sessionName: String,
        startUrl: URL,
        region: String,
        scopes: [String],
        clientName: String,
        verificationHandler: @escaping @Sendable (DeviceVerification) async -> Void
    ) async throws -> StoredSSOToken {
        let client = try await ensureOIDCClient(region: region, scopes: scopes, clientName: clientName)
        let (deviceCode, verification) = try await oidcClient.startDeviceAuthorization(
            client: client,
            startUrl: startUrl,
            sessionName: sessionName
        )

        await verificationHandler(verification)

        let token = try await pollForToken(
            client: client,
            deviceCode: deviceCode,
            sessionName: sessionName,
            verification: verification
        )

        try await keychain.writeRecord(
            token,
            service: ServiceConstants.ssoTokenService,
            account: sessionName
        )

        return token
    }

    /// Reads cached OIDC client from Keychain; re-registers if missing or near-expiry.
    private func ensureOIDCClient(
        region: String,
        scopes: [String],
        clientName: String
    ) async throws -> StoredOIDCClient {
        let service = ServiceConstants.oidcClientService
        let account = region

        if let cached = try? await keychain.readRecord(
            StoredOIDCClient.self,
            service: service,
            account: account
        ) {
            let leadTime = ServiceConstants.oidcClientReregistrationLeadTime
            let withinLeadTime = cached.secretExpiresAt.timeIntervalSinceNow < leadTime
            if !withinLeadTime {
                return cached
            }
        }

        let client = try await oidcClient.registerClient(clientName: clientName, scopes: scopes)
        try await keychain.writeRecord(client, service: service, account: account)
        return client
    }
}
