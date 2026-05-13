import Foundation

/// Actor orchestrating IAM Identity Center sign-in flows.
///
/// Owns OIDC client caching, device-grant polling, and token persistence. Each sign-in operation runs
/// in its own Task; cancellation is cooperative via `cancelSignIn(sessionName:)`.
public actor IdentityCenterService: IdentityCenterServicing {
    internal let keychain: Keychain
    internal let oidcClient: OIDCClient
    internal let sleeper: any Sleeper

    /// Map of in-flight sign-in tasks keyed by session name.
    private var inFlight: [String: Task<StoredSSOToken, Error>] = [:]

    /// Service constants (Keychain service attributes + timing constants).
    private enum ServiceConstants {
        static let oidcClientService = "dev.ajbeck.quorra.oidc-client"
        static let ssoTokenService = "dev.ajbeck.quorra.sso-token"
        static let oidcClientReregistrationLeadTime: TimeInterval = 7 * 24 * 60 * 60
        static let slowDownIncrementSeconds: TimeInterval = 5
    }

    /// Creates a service instance.
    ///
    /// - Parameters:
    ///   - keychain: Keychain actor for persisting secrets
    ///   - oidcClient: Pre-configured OIDC client for the region
    ///   - sleeper: Time source for sleep/timeout (injectable for testing)
    public init(
        keychain: Keychain,
        oidcClient: OIDCClient,
        sleeper: any Sleeper = WallClockSleeper()
    ) {
        self.keychain = keychain
        self.oidcClient = oidcClient
        self.sleeper = sleeper
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

        let task = Task<StoredSSOToken, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.runSignIn(
                sessionName: sessionName,
                startUrl: startUrl,
                region: region,
                scopes: scopes,
                clientName: clientName,
                verificationHandler: verificationHandler
            )
        }
        inFlight[sessionName] = task

        defer { inFlight[sessionName] = nil }

        do {
            return try await task.value
        } catch is CancellationError {
            throw IAMIdentityCenterError.userCancelled
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
