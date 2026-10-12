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
    internal let oidcClientProvider: any OIDCClientProviding
    internal let sleeper: any Sleeper
    /// URLSession for Portal /logout calls. Injectable for tests.
    internal let urlSession: URLSession
    /// Portal client for role-credential mint operations. Injectable for tests.
    internal let portalClient: any PortalRequesting

    /// Map of in-flight sign-in tasks keyed by session name.
    private var inFlight: [String: Task<StoredSSOToken, Error>] = [:]

    /// Expiration timers keyed by session name (D8 / D11).
    var expirationTimers: [String: Task<Void, Never>] = [:]

    /// Refresh timers keyed by session name — fires at the token's adaptive refresh deadline (D11 / A2).
    var refreshTimers: [String: Task<Void, Never>] = [:]

    /// In-flight refresh tasks keyed by session name. Single-flight coalescing (D12 / A2).
    var inFlightRefresh: [String: Task<StoredSSOToken, Error>] = [:]

    /// In-flight mint tasks keyed by "<sessionName>:<accountId>:<roleName>". Single-flight coalescing (D26 / B).
    var inFlightMint: [String: Task<RoleCredentials, Error>] = [:]

    /// Proactive mint timers keyed by "<sessionName>:<accountId>:<roleName>" — fires at
    /// the credential's adaptive refresh deadline to pre-warm Scope C's IMDS endpoint (D28 / B).
    var mintTimers: [String: Task<Void, Never>] = [:]

    /// Per-session Task chain for async serialization (D21 / A2).
    var sessionLocks: [String: Task<Void, Never>] = [:]

    /// Service constants (Keychain service attributes + timing constants).
    enum ServiceConstants {
        static let oidcClientService = "dev.ajbeck.quorra.oidc-client"
        static let ssoTokenService = "dev.ajbeck.quorra.sso-token"
        static let roleCredsService = "dev.ajbeck.quorra.role-creds"
        static let oidcClientReregistrationLeadTime: TimeInterval = 7 * 24 * 60 * 60
        static let slowDownIncrementSeconds: TimeInterval = 5
        /// Maximum refresh skew. Long-lived tokens retain the established five-minute window.
        static let maximumRefreshSkew: TimeInterval = 5 * 60
        /// Short-lived values use this fraction of their original issued lifetime.
        static let refreshSkewFraction = 0.10

        /// Returns an adaptive skew based on original lifetime, capped at five minutes.
        /// Invalid or non-positive lifetimes have no pre-expiration skew.
        static func refreshSkew(issuedAt: Date, expiresAt: Date) -> TimeInterval {
            let lifetime = max(0, expiresAt.timeIntervalSince(issuedAt))
            return min(maximumRefreshSkew, lifetime * refreshSkewFraction)
        }

        static func refreshDeadline(issuedAt: Date, expiresAt: Date) -> Date {
            expiresAt.addingTimeInterval(-refreshSkew(issuedAt: issuedAt, expiresAt: expiresAt))
        }
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
    ///   - oidcClientProvider: Factory that builds a region-correct OIDC client on demand
    ///   - portalClient: Portal client for `GetRoleCredentials` calls (default: `PortalClient()`)
    ///   - sleeper: Time source for sleep/timeout (injectable for testing)
    public init(
        keychain: any KeychainStore,
        oidcClientProvider: any OIDCClientProviding,
        portalClient: any PortalRequesting = PortalClient(),
        sleeper: any Sleeper = WallClockSleeper(),
        urlSession: URLSession = .shared
    ) {
        self.keychain = keychain
        self.oidcClientProvider = oidcClientProvider
        self.portalClient = portalClient
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

    /// Drives the full sign-in flow.
    ///
    /// Signs in through the browser with the authorization code grant and PKCE (RFC 7636): the
    /// handler receives the authorize URL, and a one-use loopback listener receives the code.
    /// When `useDeviceCode` is set, or the loopback listener cannot start, it uses the device code
    /// grant instead: the handler receives the user code and the token is polled for. Both paths
    /// use the session's own OIDC client, registered once for both grants, so either token refreshes.
    ///
    /// Emits `.signInStarted`, then one of `.signedIn` / `.signInCancelled` / `.signInFailed` (D2).
    ///
    /// - Parameters:
    ///   - sessionName: SSO session name (from `~/.aws/config` `[sso-session NAME]`)
    ///   - startUrl: Identity Center start URL
    ///   - region: AWS region (e.g. "us-east-1")
    ///   - scopes: OIDC scopes (must include "sso:account:access" for refresh token issuance)
    ///   - clientName: Human-readable client name (default: "Quorra")
    ///   - useDeviceCode: Sign in with a device code instead of the browser callback
    ///   - verificationHandler: Async callback invoked once with the page to open (and the user code, if any)
    /// - Returns: Stored SSO token
    /// - Throws: `.invalidClient`, `.expiredDeviceCode`, `.accessDenied`, `.deviceFlowTimedOut`, `.signInAlreadyInProgress`, `.userCancelled`, or transport errors
    public func signIn(
        sessionName: String,
        startUrl: URL,
        region: String,
        scopes: [String],
        clientName: String = "Quorra",
        useDeviceCode: Bool = false,
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
                    useDeviceCode: useDeviceCode,
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
                scheduleRefresh(
                    forSession: sessionName,
                    issuedAt: token.issuedAt,
                    expiresAt: token.expiresAt
                )
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
        useDeviceCode: Bool,
        verificationHandler: @escaping @Sendable (DeviceVerification) async -> Void
    ) async throws -> StoredSSOToken {
        let client = try await ensureSessionClient(
            region: region,
            startUrl: startUrl,
            scopes: scopes,
            clientName: clientName
        )

        var browserToken: StoredSSOToken?
        if !useDeviceCode {
            browserToken = try await browserSignIn(
                client: client,
                region: region,
                scopes: scopes,
                sessionName: sessionName,
                verificationHandler: verificationHandler
            )
        }

        let token: StoredSSOToken
        if let browserToken {
            token = browserToken
        } else {
            token = try await deviceSignIn(
                client: client,
                region: region,
                startUrl: startUrl,
                scopes: scopes,
                clientName: clientName,
                sessionName: sessionName,
                verificationHandler: verificationHandler
            )
        }

        let boundToken = token.boundToClient(Self.sessionClientAccount(region: region, startUrl: startUrl))
        try await keychain.writeRecord(
            boundToken,
            service: ServiceConstants.ssoTokenService,
            account: sessionName
        )

        return boundToken
    }

    /// Signs in with the authorization code grant and PKCE. Returns `nil` when the loopback
    /// callback cannot start, so the caller falls back to a device code.
    private func browserSignIn(
        client: StoredOIDCClient,
        region: String,
        scopes: [String],
        sessionName: String,
        verificationHandler: @escaping @Sendable (DeviceVerification) async -> Void
    ) async throws -> StoredSSOToken? {
        let pkce = try OAuthPKCE.generate()
        let listener = await LoopbackOAuthListener(expectedState: pkce.state, sessionName: sessionName)

        let redirectURI: URL
        do {
            redirectURI = try await listener.start()
        } catch BrowserSignInError.callbackUnavailable {
            logger.notice("Browser sign-in callback unavailable; falling back to a device code")
            return nil
        }

        do {
            let authorizationURL = try pkce.authorizationURL(
                region: region,
                clientID: client.clientId,
                redirectURI: redirectURI,
                scopes: scopes
            )
            await verificationHandler(DeviceVerification(
                userCode: nil,
                verificationUri: authorizationURL,
                verificationUriComplete: authorizationURL,
                expiresAt: await sleeper.now.addingTimeInterval(TimeInterval(LoopbackOAuthListener.defaultLifetime.components.seconds)),
                interval: 0
            ))
            let code = try await listener.authorizationCode()
            let oidc = try await oidcClientProvider.client(forRegion: region)
            return try await oidc.exchangeAuthorizationCode(
                client: client,
                code: code,
                codeVerifier: pkce.verifier,
                redirectUri: redirectURI.absoluteString,
                sessionName: sessionName
            )
        } catch let error as BrowserSignInError {
            await listener.cancel()
            switch error {
            case .accessDenied:
                throw IAMIdentityCenterError.accessDenied
            case .timedOut:
                throw IAMIdentityCenterError.deviceFlowTimedOut
            case .callbackUnavailable, .invalidCallback:
                throw IAMIdentityCenterError.malformedResponse("The browser sign-in could not be completed")
            }
        } catch {
            await listener.cancel()
            throw error
        }
    }

    /// Signs in with the device code grant: shows the user code, then polls for the token.
    ///
    /// A cached registration can be invalidated out from under us (revoked or deleted
    /// server-side). That surfaces as `.invalidClient` on first use; the documented recovery is
    /// to re-register, so the client is replaced and device authorization retried exactly once.
    private func deviceSignIn(
        client: StoredOIDCClient,
        region: String,
        startUrl: URL,
        scopes: [String],
        clientName: String,
        sessionName: String,
        verificationHandler: @escaping @Sendable (DeviceVerification) async -> Void
    ) async throws -> StoredSSOToken {
        let oidc = try await oidcClientProvider.client(forRegion: region)
        var activeClient = client
        let deviceCode: String
        let verification: DeviceVerification
        do {
            (deviceCode, verification) = try await oidc.startDeviceAuthorization(
                client: client,
                startUrl: startUrl,
                sessionName: sessionName
            )
        } catch IAMIdentityCenterError.invalidClient {
            logger.notice("Cached OIDC client rejected (invalidClient) for region \(region, privacy: .public); re-registering and retrying device authorization")
            activeClient = try await ensureSessionClient(
                region: region,
                startUrl: startUrl,
                scopes: scopes,
                clientName: clientName,
                forceReregister: true
            )
            (deviceCode, verification) = try await oidc.startDeviceAuthorization(
                client: activeClient,
                startUrl: startUrl,
                sessionName: sessionName
            )
        }

        await verificationHandler(verification)

        return try await pollForToken(
            client: activeClient,
            deviceCode: deviceCode,
            sessionName: sessionName,
            verification: verification
        )
    }

    /// Keychain account of a session's OIDC client: one per Identity Center instance and region.
    static func sessionClientAccount(region: String, startUrl: URL) -> String {
        "\(region) \(startUrl.absoluteString)"
    }

    /// Reads the session's cached OIDC client from Keychain; registers a new one if missing,
    /// near expiry, registered for other scopes or grants, or when `forceReregister` is set.
    /// A registration is long-lived (`clientSecretExpiresAt` ~90 days) and must persist across
    /// restarts so silent refresh works: AWS binds a refresh token to the client that minted it.
    private func ensureSessionClient(
        region: String,
        startUrl: URL,
        scopes: [String],
        clientName: String,
        forceReregister: Bool = false
    ) async throws -> StoredOIDCClient {
        let service = ServiceConstants.oidcClientService
        let account = Self.sessionClientAccount(region: region, startUrl: startUrl)

        if !forceReregister, let cached = try? await keychain.readRecord(
            StoredOIDCClient.self,
            service: service,
            account: account
        ) {
            let leadTime = ServiceConstants.oidcClientReregistrationLeadTime
            let withinLeadTime = cached.secretExpiresAt.timeIntervalSinceNow < leadTime
            let scopeMatches = Set(cached.scopes) == Set(scopes)
            let grantsMatch = Set(cached.grantTypes ?? []) == Set(OAuthGrant.sessionClientGrants)
            if !withinLeadTime, scopeMatches, grantsMatch {
                return cached
            }
        }

        let oidc = try await oidcClientProvider.client(forRegion: region)
        let client = try await oidc.registerSessionClient(
            clientName: clientName,
            scopes: scopes,
            issuerUrl: startUrl,
            redirectUri: OAuthGrant.redirectUri
        )
        try await keychain.writeRecord(client, service: service, account: account)
        return client
    }
}
