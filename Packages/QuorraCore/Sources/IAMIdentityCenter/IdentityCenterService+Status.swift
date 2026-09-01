import Foundation
import OSLog
import Security

private let statusLogger = Logger(subsystem: "dev.ajbeck.quorra", category: "IAMIdentityCenter.Status")

extension IdentityCenterService {
    // MARK: - Status verb (D6, D7)

    /// Returns the current authentication status for `sessionName`.
    ///
    /// `@concurrent` satisfies the protocol's isolation requirement; immediately hops to the
    /// actor's isolated context via `self.computeStatus(forSession:)`.
    ///
    /// A2 (D17): never returns `.refreshing` — that case was removed from `SessionAuthStatus`.
    /// During refresh the status remains `.signedIn(expiresAt:, canRefresh:)`; the `refreshingNow`
    /// overlay in `CredentialsModel` drives the UI indication.
    @concurrent
    public func status(forSession sessionName: String) async -> SessionAuthStatus {
        await self.computeStatus(forSession: sessionName)
    }

    /// Actor-isolated body of status. Reads Keychain, absorbs errors per D7, opportunistically
    /// schedules both timers on app restart (D8 trigger #3 / D11).
    func computeStatus(forSession sessionName: String) async -> SessionAuthStatus {
        // In-flight sign-in takes precedence — live status is `.signingIn`
        if inFlightTask(for: sessionName) != nil {
            return .signingIn
        }

        let token: StoredSSOToken
        do {
            token = try await keychain.readRecord(
                StoredSSOToken.self,
                service: ServiceConstants.ssoTokenService,
                account: sessionName
            )
        } catch IAMIdentityCenterError.keychainItemMissing {
            return .signedOut
        } catch IAMIdentityCenterError.keychainMalformed(let reason) {
            statusLogger.warning("Malformed SSO token in Keychain for session '\(sessionName, privacy: .public)': \(reason, privacy: .public)")
            return .signedOut
        } catch IAMIdentityCenterError.keychainStatus(errSecMissingEntitlement) {
            // TN3137: data-protection keychain items are tied to the signing identity that
            // wrote them. errSecMissingEntitlement (-34018) here means the current build can't
            // claim the row — most commonly a stale row from a previous Xcode dev cert or a
            // misconfigured entitlement. Functionally equivalent to a missing row; a successful
            // sign-in will overwrite it. Log at .info so it doesn't masquerade as a real fault.
            statusLogger.info(
                "Stale Keychain row for session '\(sessionName, privacy: .public)' (errSecMissingEntitlement) — sign in again to replace it."
            )
            return .signedOut
        } catch {
            statusLogger.warning("Keychain read failed for session '\(sessionName, privacy: .public)': \(error, privacy: .public)")
            return .signedOut
        }

        let canRefresh = token.refreshToken != nil
        let now = Date()

        if now >= token.expiresAt {
            // Expired — don't schedule a timer (it already fired or we're past it)
            return .expired(expiredAt: token.expiresAt, canRefresh: canRefresh)
        }

        // Valid token found — opportunistically schedule both T_expire and T_refresh
        // if they don't already exist. This handles the "app restart with a valid stored token"
        // case (D8 trigger #3 / D11).
        if expirationTimers[sessionName] == nil {
            scheduleExpiration(forSession: sessionName, expiresAt: token.expiresAt)
        }
        if canRefresh && refreshTimers[sessionName] == nil && inFlightRefresh[sessionName] == nil {
            scheduleRefresh(
                forSession: sessionName,
                issuedAt: token.issuedAt,
                expiresAt: token.expiresAt
            )
        }

        return .signedIn(expiresAt: token.expiresAt, canRefresh: canRefresh)
    }
}
