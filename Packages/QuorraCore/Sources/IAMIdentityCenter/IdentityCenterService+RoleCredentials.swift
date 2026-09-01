import Foundation
import OSLog

private let roleCredsLogger = Logger(subsystem: "dev.ajbeck.quorra", category: "IAMIdentityCenter.RoleCredentials")

extension IdentityCenterService {
    // MARK: - Live credentials (D25, D26)

    /// Returns `RoleCredentials` outside their adaptive refresh window.
    ///
    /// Contract per D26:
    /// - Cached row exists, `now < expiresAt − skew` → return cached
    /// - Inside skew (`now ≥ expiresAt − skew, now < expiresAt`) → inline mint
    /// - Past expiry, bearer valid → inline mint
    /// - No cached row → inline mint
    /// - Mint already in flight for same tuple → await `inFlightMint[key]` (D26 coalescing)
    /// - `liveToken` throws `.notSignedIn`/`.tokenExpired` → propagate
    /// - AWS `ForbiddenException` → throw `.roleNotAssigned`, purge cached row
    /// - AWS `ResourceNotFoundException` → throw `.accountNotFound`, purge cached row
    /// - Network / 5xx transient → propagate, NO Keychain mutation
    ///
    /// Does NOT take the session lock (D26). `liveToken` internally takes the session lock when
    /// fetching the SSO bearer; by the time we call `portal.getRoleCredentials`, the bearer is
    /// fresh and the lock has been released. `inFlightMint` coalesces mint-vs-mint races for the
    /// same tuple. Sign-out cancels every `inFlightMint[*]` for the session (D27, chunk 5).
    ///
    /// Apple: Swift/AsyncSequence — actor-isolated mutation of `inFlightMint` is safe because
    /// only actor-bound methods touch it.
    @concurrent
    public func liveCredentials(
        forSession sessionName: String,
        accountId: String,
        roleName: String,
        region: String
    ) async throws -> RoleCredentials {
        try await self.performLiveCredentials(
            sessionName: sessionName,
            accountId: accountId,
            roleName: roleName,
            region: region
        )
    }

    /// Forces a fresh role-credential mint, bypassing any cached row that is still outside the
    /// normal refresh skew. Used by explicit UI renewal actions where returning the cached row
    /// would make the user's command appear to do nothing.
    @concurrent
    public func renewCredentials(
        forSession sessionName: String,
        accountId: String,
        roleName: String,
        region: String
    ) async throws -> RoleCredentials {
        let key = "\(sessionName):\(accountId):\(roleName)"
        return try await self.startInlineMint(
            sessionName: sessionName,
            accountId: accountId,
            roleName: roleName,
            region: region,
            key: key
        )
    }

    func performLiveCredentials(
        sessionName: String,
        accountId: String,
        roleName: String,
        region: String
    ) async throws -> RoleCredentials {
        let key = "\(sessionName):\(accountId):\(roleName)"

        // Coalesce with an existing in-flight mint for this tuple (D26)
        if let existing = inFlightMint[key] {
            return try await existing.value
        }

        // Attempt to read a cached row from the Keychain
        let cached = try? await keychain.readRecord(
            RoleCredentials.self,
            service: ServiceConstants.roleCredsService,
            account: key
        )

        if let cached {
            let now = Date()
            let refreshDeadline = ServiceConstants.refreshDeadline(
                issuedAt: cached.issuedAt,
                expiresAt: cached.expiresAt
            )
            if now < refreshDeadline {
                // Outside skew window — credentials are fresh, return without minting
                return cached
            }
            // Inside skew or past expiry — fall through to inline mint
        }
        // No cached row — fall through to inline mint

        return try await startInlineMint(
            sessionName: sessionName,
            accountId: accountId,
            roleName: roleName,
            region: region,
            key: key
        )
    }

    // MARK: - Internal mint plumbing

    /// Starts a single-flight mint task and registers it in `inFlightMint`.
    ///
    /// Because `performLiveCredentials` suspends on `readRecord` before reaching here, a second
    /// concurrent caller may also have passed the initial `inFlightMint` nil-check. This guard
    /// handles that race: if a task was registered while we were suspended, coalesce onto the
    /// existing one instead of starting a second Portal call (D26 — mirrors D12 fix in A2).
    ///
    /// `internal` (not `private`) so `handleMint` in `+Mint.swift` can route the timer-fired
    /// path through here, keeping single-flight + provenance construction in one place (D28).
    func startInlineMint(
        sessionName: String,
        accountId: String,
        roleName: String,
        region: String,
        key: String
    ) async throws -> RoleCredentials {
        // Re-check after potential suspension in performLiveCredentials (D26 coalescing race fix)
        if let existing = inFlightMint[key] {
            return try await existing.value
        }

        let task = Task<RoleCredentials, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.runMintBody(
                sessionName: sessionName,
                accountId: accountId,
                roleName: roleName,
                region: region,
                key: key
            )
        }
        inFlightMint[key] = task
        defer { inFlightMint[key] = nil }
        return try await task.value
    }

    /// Executes the actual mint: fetch bearer via `liveToken`, call Portal, construct
    /// provenance-bearing `RoleCredentials`, write Keychain.
    ///
    /// Error handling per D26:
    /// - `.roleNotAssigned` / `.accountNotFound` → purge cached row (terminal for this tuple)
    /// - Transient errors → propagate, leave Keychain unchanged
    private func runMintBody(
        sessionName: String,
        accountId: String,
        roleName: String,
        region: String,
        key: String
    ) async throws -> RoleCredentials {
        // Fetch a fresh bearer. `liveToken` internally handles the session lock (D26 — we do NOT
        // take it again here to avoid deadlock). Throws `.notSignedIn` / `.tokenExpired` on failure.
        let bearer = try await liveToken(forSession: sessionName)

        // D30: emit mintingCredentials immediately before the Portal call (bearer is in hand).
        // Mirrors A2's `eventContinuation.yield(.refreshing(...))` placement in runRefreshBody.
        eventContinuation.yield(.mintingCredentials(sessionName: sessionName, accountId: accountId, roleName: roleName))

        let minted: MintedCredential
        do {
            minted = try await portalClient.getRoleCredentials(
                accessToken: bearer.accessToken,
                accountId: accountId,
                roleName: roleName,
                region: region
            )
        } catch IAMIdentityCenterError.roleNotAssigned {
            // Terminal for this tuple — purge cached row so the next liveCredentials call retries
            try? await keychain.deleteRecord(
                service: ServiceConstants.roleCredsService,
                account: key
            )
            // D30: one roleAccessDenied covers both ForbiddenException and ResourceNotFoundException
            eventContinuation.yield(.roleAccessDenied(sessionName: sessionName, accountId: accountId, roleName: roleName))
            throw IAMIdentityCenterError.roleNotAssigned
        } catch IAMIdentityCenterError.accountNotFound {
            // Terminal for this tuple — purge cached row
            try? await keychain.deleteRecord(
                service: ServiceConstants.roleCredsService,
                account: key
            )
            // D30: one roleAccessDenied covers both ForbiddenException and ResourceNotFoundException
            eventContinuation.yield(.roleAccessDenied(sessionName: sessionName, accountId: accountId, roleName: roleName))
            throw IAMIdentityCenterError.accountNotFound
        } catch {
            // Transient errors (network, 5xx) — no Keychain mutation; D30: emit mintCredentialsFailed
            eventContinuation.yield(.mintCredentialsFailed(sessionName: sessionName, accountId: accountId, roleName: roleName))
            throw error
        }

        // D23/D24 amendment: actor constructs the full provenance-bearing RoleCredentials.
        // `sessionName` is the caller-supplied value — NOT the empty string — closing the
        // deferred amendment bug described in the chunk-2 spec.
        let creds = RoleCredentials(
            accessKeyId: minted.accessKeyId,
            secretAccessKey: minted.secretAccessKey,
            sessionToken: minted.sessionToken,
            expiresAt: minted.expiresAt,
            accountId: accountId,
            roleName: roleName,
            region: region,
            sessionName: sessionName,
            issuedAt: Date()
        )

        try await keychain.writeRecord(
            creds,
            service: ServiceConstants.roleCredsService,
            account: key
        )

        // D30: emit mintedCredentials after Keychain write succeeds (mirrors A2's .refreshed placement).
        eventContinuation.yield(.mintedCredentials(sessionName: sessionName, accountId: accountId, roleName: roleName))

        // D28: on successful mint, schedule (or reschedule) the proactive T_mint timer at the new
        // credential's deadline. Cancel-old-then-schedule-new mirrors A2's runRefreshBody pattern
        // for T_refresh. The timer fires `handleMint`, which routes back through startInlineMint
        // so a fresh row is pre-warmed before the current one enters the skew window.
        cancelMint(forKey: key)
        scheduleMint(
            forSession: sessionName,
            accountId: accountId,
            roleName: roleName,
            region: region,
            issuedAt: creds.issuedAt,
            expiresAt: creds.expiresAt
        )

        roleCredsLogger.debug("Minted role credentials: \(creds)")
        return creds
    }
}
