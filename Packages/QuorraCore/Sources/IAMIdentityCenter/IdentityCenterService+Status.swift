import Foundation
import OSLog

private let statusLogger = Logger(subsystem: "dev.ajbeck.quorra", category: "IAMIdentityCenter.Status")

extension IdentityCenterService {
    // MARK: - Status verb (D6, D7)

    /// Returns the current authentication status for `sessionName`.
    ///
    /// `@concurrent` satisfies the protocol's isolation requirement; immediately hops to the
    /// actor's isolated context via `self.computeStatus(forSession:)`.
    @concurrent
    public func status(forSession sessionName: String) async -> SessionAuthStatus {
        await self.computeStatus(forSession: sessionName)
    }

    /// Actor-isolated body of status. Reads Keychain, absorbs errors per D7, opportunistically
    /// schedules the expiration timer on app restart (D8 trigger #3).
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

        // Valid token found — opportunistically schedule the expiration timer if none exists (D8).
        // This handles the "app restart with a valid stored token" case.
        if expirationTimers[sessionName] == nil {
            scheduleExpiration(forSession: sessionName, expiresAt: token.expiresAt)
        }

        return .signedIn(expiresAt: token.expiresAt, canRefresh: canRefresh)
    }
}
