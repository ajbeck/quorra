import Foundation
import OSLog

private let refreshLogger = Logger(subsystem: "dev.ajbeck.quorra", category: "IAMIdentityCenter.Refresh")

extension IdentityCenterService {
    // MARK: - Live token (D10, D12)

    /// Returns a `StoredSSOToken` guaranteed to be valid for at least `refreshSkew` seconds.
    ///
    /// Contract per D12:
    /// - now < expiresAt − skew, no in-flight refresh → return current token from Keychain
    /// - now ≥ expiresAt − skew, now < expiresAt (inside skew) → trigger refresh inline
    /// - now ≥ expiresAt, canRefresh: true → trigger refresh inline (timer was late: cold start, sleep edge)
    /// - now ≥ expiresAt, canRefresh: false → throw `.tokenExpired`
    /// - refresh already in flight → await `inFlightRefresh[name]`; return shared result
    /// - Keychain says signedOut → throw `.notSignedIn`
    ///
    /// This is the single read path Scope B (role credentials) and Scope C (IMDS) will use.
    /// No actor-side cache (D13) — Keychain is source of truth.
    @concurrent
    public func liveToken(forSession sessionName: String) async throws -> StoredSSOToken {
        try await self.performLiveToken(sessionName: sessionName)
    }

    func performLiveToken(sessionName: String) async throws -> StoredSSOToken {
        // If there's already an in-flight refresh, coalesce — don't start a second one (D12)
        if let existing = inFlightRefresh[sessionName] {
            return try await existing.value
        }

        let token: StoredSSOToken
        do {
            token = try await keychain.readRecord(
                StoredSSOToken.self,
                service: ServiceConstants.ssoTokenService,
                account: sessionName
            )
        } catch IAMIdentityCenterError.keychainItemMissing {
            throw IAMIdentityCenterError.notSignedIn
        }

        let now = Date()
        let skew = ServiceConstants.refreshSkew

        if now < token.expiresAt.addingTimeInterval(-skew) {
            // Outside skew window — token is fresh, return without refresh
            return token
        }

        // Inside skew window or past expiry
        if now >= token.expiresAt && token.refreshToken == nil {
            // Expired and no refresh token — user must sign in
            throw IAMIdentityCenterError.tokenExpired
        }

        // Trigger inline refresh (handles both "inside skew" and "past expiry with canRefresh: true")
        return try await startInlineRefresh(sessionName: sessionName)
    }

    /// Programmatic refresh verb. Always starts a fresh refresh attempt (or coalesces with
    /// an existing in-flight one). Available for UI buttons and Scope B programmatic calls.
    ///
    /// UI: surfaces only on transient `.refreshFailed` (D16).
    @concurrent
    public func refreshNow(sessionName: String) async throws -> StoredSSOToken {
        try await self.performRefreshNow(sessionName: sessionName)
    }

    func performRefreshNow(sessionName: String) async throws -> StoredSSOToken {
        // Coalesce with any existing in-flight refresh without taking the lock (D12).
        // Two concurrent callers that both reach here with an in-flight task share the result.
        if let existing = inFlightRefresh[sessionName] {
            return try await existing.value
        }
        // No in-flight refresh — take the session lock (D21) and start one.
        // startInlineRefresh double-checks inFlightRefresh inside the lock to handle
        // the race where another caller raced past the check above.
        return try await withSessionLock(sessionName) {
            try await self.startInlineRefresh(sessionName: sessionName)
        }
    }

    // MARK: - Internal refresh plumbing

    /// Starts a single-flight refresh task and registers it in `inFlightRefresh`.
    ///
    /// Because `performLiveToken` suspends on `readRecord` before reaching here, a second
    /// concurrent caller may also have passed the initial `inFlightRefresh` nil-check. This
    /// guard handles that race: if a task was registered while we were suspended, coalesce
    /// onto the existing one instead of starting a second network call (D12).
    private func startInlineRefresh(sessionName: String) async throws -> StoredSSOToken {
        // Re-check after potential suspension in performLiveToken (D12 coalescing)
        if let existing = inFlightRefresh[sessionName] {
            return try await existing.value
        }
        let task = Task<StoredSSOToken, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.runRefreshBody(sessionName: sessionName)
        }
        inFlightRefresh[sessionName] = task
        defer { inFlightRefresh[sessionName] = nil }
        return try await task.value
    }

    /// Shared body invoked by both the inline path (`liveToken`/`refreshNow`) and
    /// `performRunRefresh` (timer path). Emits events, writes Keychain, reschedules timers.
    private func runRefreshBody(sessionName: String) async throws -> StoredSSOToken {
        // Read current token from Keychain (D13 — no actor cache)
        let oldToken: StoredSSOToken
        do {
            oldToken = try await keychain.readRecord(
                StoredSSOToken.self,
                service: ServiceConstants.ssoTokenService,
                account: sessionName
            )
        } catch IAMIdentityCenterError.keychainItemMissing {
            throw IAMIdentityCenterError.notSignedIn
        }

        guard let refreshToken = oldToken.refreshToken else {
            throw IAMIdentityCenterError.tokenExpired
        }

        // Get the OIDC client (needed for clientId/clientSecret)
        let client = try await ensureRefreshClient(region: oldToken.region)

        eventContinuation.yield(.refreshing(sessionName: sessionName))

        let newToken: StoredSSOToken
        do {
            let oidc = try await oidcClientProvider.client(forRegion: oldToken.region)
            newToken = try await oidc.refreshToken(
                client: client,
                refreshToken: refreshToken,
                sessionName: sessionName
            )
        } catch {
            try await handleRefreshFailure(
                error: error,
                sessionName: sessionName,
                oldToken: oldToken
            )
            throw error
        }

        // Success — write new token to Keychain, reschedule both timers (D11)
        try await keychain.writeRecord(
            newToken,
            service: ServiceConstants.ssoTokenService,
            account: sessionName
        )

        cancelExpiration(forSession: sessionName)
        cancelRefresh(forSession: sessionName)
        scheduleExpiration(forSession: sessionName, expiresAt: newToken.expiresAt)
        if newToken.refreshToken != nil {
            scheduleRefresh(forSession: sessionName, expiresAt: newToken.expiresAt)
        }

        eventContinuation.yield(.refreshed(sessionName: sessionName))
        return newToken
    }

    /// Timer-driven entry point. Called by `handleRefresh(sessionName:)` in Expiration.swift.
    ///
    /// Routes through `performRefreshNow` so the timer path uses the same coalescing logic as
    /// the inline path — avoids the redundancy of blindly assigning to `inFlightRefresh` without
    /// a prior nil-check. `handleRefresh` in Expiration.swift already guards on
    /// `inFlightRefresh == nil`, but routing here is the clean canonical path (D20 / D21).
    func performRunRefresh(sessionName: String) async {
        _ = try? await performRefreshNow(sessionName: sessionName)
    }

    // MARK: - Refresh failure handling (D14)

    /// Handles a refresh failure. Terminal errors nil-out the refresh token in Keychain
    /// (preserving the access token + expiresAt). Transient errors leave Keychain unchanged.
    private func handleRefreshFailure(
        error: Error,
        sessionName: String,
        oldToken: StoredSSOToken
    ) async throws {
        refreshTimers[sessionName]?.cancel()
        refreshTimers[sessionName] = nil

        let isTerminal: Bool
        if let iam = error as? IAMIdentityCenterError {
            switch iam {
            case .refreshTokenRejected, .refreshClientInvalid:
                isTerminal = true
            default:
                isTerminal = false
            }
        } else {
            isTerminal = false
        }

        if isTerminal {
            // Nil-out the refresh token in Keychain; keep accessToken + expiresAt.
            // The access token may still be valid for minutes; status becomes signedIn(_, canRefresh: false).
            let updatedToken = StoredSSOToken(
                accessToken: oldToken.accessToken,
                expiresAt: oldToken.expiresAt,
                refreshToken: nil,
                issuedAt: oldToken.issuedAt,
                region: oldToken.region,
                sessionName: oldToken.sessionName
            )
            try await keychain.writeRecord(
                updatedToken,
                service: ServiceConstants.ssoTokenService,
                account: sessionName
            )
        }
        // T_expire is left running in both cases so .expired fires at the original deadline

        eventContinuation.yield(.refreshFailed(sessionName: sessionName))
    }

    // MARK: - Client helpers

    /// Reads (or re-registers) the OIDC client for the given region.
    private func ensureRefreshClient(region: String) async throws -> StoredOIDCClient {
        let service = ServiceConstants.oidcClientService
        if let cached = try? await keychain.readRecord(
            StoredOIDCClient.self,
            service: service,
            account: region
        ) {
            return cached
        }
        // Client missing — can't refresh without it; treat as terminal client error
        throw IAMIdentityCenterError.refreshClientInvalid
    }
}
