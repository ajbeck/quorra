import Foundation
import OSLog
import Security

private let profileStatusLogger = Logger(subsystem: "dev.ajbeck.quorra", category: "IAMIdentityCenter.ProfileStatus")

extension IdentityCenterService {
    // MARK: - Profile status verb (D29)

    /// Returns the current `ProfileAuthStatus` for a `(sessionName, accountId, roleName)` tuple.
    ///
    /// `@concurrent` satisfies the protocol's isolation requirement; immediately hops to the
    /// actor's isolated context via `computeProfileStatus(...)`. Non-throwing — absorbs Keychain
    /// errors and maps them to a status, mirroring A1's `status(forSession:)` posture.
    @concurrent
    public func status(
        forProfile sessionName: String,
        accountId: String,
        roleName: String
    ) async -> ProfileAuthStatus {
        await self.computeProfileStatus(
            sessionName: sessionName,
            accountId: accountId,
            roleName: roleName
        )
    }

    /// Actor-isolated body. Derives profile readiness from the underlying `SessionAuthStatus`,
    /// then (D28 deferred trigger) opportunistically schedules `T_mint` when a cached role-cred
    /// row exists and the bearer is valid — chunk 3 deferred this until the status verb existed.
    func computeProfileStatus(
        sessionName: String,
        accountId: String,
        roleName: String
    ) async -> ProfileAuthStatus {
        // Reuse A1's session-status computation as the source of truth for the bearer.
        let sessionStatus = await computeStatus(forSession: sessionName)

        switch sessionStatus {
        case .signedOut:
            return .notSignedIn(sessionName: sessionName)
        case .signingIn:
            // A device-authorization flow is in progress — no usable bearer yet. Within the
            // three-case D29 enum this is honestly "not signed in (yet)"; a chunk-6 overlay
            // can surface the in-progress indication separately if desired.
            return .notSignedIn(sessionName: sessionName)
        case .expired(_, canRefresh: false):
            return .signInExpired(sessionName: sessionName)
        case .expired(_, canRefresh: true), .signedIn:
            // Bearer is valid or silently refreshable — profile is "ready" per research §09.
            break
        }

        // Bearer is good. Read the cached role-cred row (if any). A stale or absent row is
        // still "ready" — the next liveCredentials call mints transparently (§09).
        let key = "\(sessionName):\(accountId):\(roleName)"
        let cached: RoleCredentials?
        do {
            cached = try await keychain.readRecord(
                RoleCredentials.self,
                service: ServiceConstants.roleCredsService,
                account: key
            )
        } catch IAMIdentityCenterError.keychainItemMissing {
            cached = nil
        } catch IAMIdentityCenterError.keychainMalformed(let reason) {
            profileStatusLogger.warning("Malformed role-creds row for '\(key, privacy: .public)': \(reason, privacy: .public)")
            cached = nil
        } catch IAMIdentityCenterError.keychainStatus(errSecMissingEntitlement) {
            // TN3137: data-protection keychain items are tied to the signing identity that
            // wrote them. errSecMissingEntitlement (-34018) here means the current build can't
            // claim the row — typically a stale row from a previous Xcode dev cert. Treat as
            // missing; the next successful mint will overwrite it.
            profileStatusLogger.info(
                "Stale role-creds row for '\(key, privacy: .public)' (errSecMissingEntitlement) — will be replaced on next mint."
            )
            cached = nil
        } catch {
            profileStatusLogger.warning("Role-creds Keychain read failed for '\(key, privacy: .public)': \(error, privacy: .public)")
            cached = nil
        }

        // D28 opportunistic trigger: if a cached row exists and no T_mint / in-flight mint is
        // already running for this tuple, schedule the proactive timer so the credential is
        // pre-warmed before it enters the skew window. Mirrors A1's computeStatus scheduling
        // both timers opportunistically on app restart. Uses the row's own region/expiresAt.
        if let cached, mintTimers[key] == nil, inFlightMint[key] == nil {
            scheduleMint(
                forSession: sessionName,
                accountId: accountId,
                roleName: roleName,
                region: cached.region,
                expiresAt: cached.expiresAt
            )
        }

        return .ready(expiresAt: cached?.expiresAt)
    }
}
