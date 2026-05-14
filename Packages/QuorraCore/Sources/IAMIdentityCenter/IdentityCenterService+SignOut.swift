import Foundation

extension IdentityCenterService {
    // MARK: - Sign-out flow (D3 / D21)

    /// Signs out the session identified by `sessionName`.
    ///
    /// `@concurrent` satisfies the protocol's isolation requirement; immediately hops to the
    /// actor's isolated context via `self.performSignOut(sessionName:)`.
    ///
    /// Order of operations per D3 + D21:
    /// 1. Cancel any in-flight refresh (cancel-then-queue per D21).
    /// 2. Cancel any in-flight sign-in for this session and wait for it to unwind.
    /// 3. Read the `StoredSSOToken` from Keychain. If missing, emit `.signedOut` and return (idempotent).
    /// 4. Cancel both timers (T_expire + T_refresh).
    /// 5. Emit `.signedOut(sessionName:)` — UI flips immediately.
    /// 6. Delete the SSO token Keychain row.
    /// 7. Fire `POST /logout` to the Portal (best-effort, injected URLSession for testability).
    /// 8. If step 7 fails: emit `.signOutServerSideFailed(sessionName:)` — do NOT throw.
    ///
    /// - Parameter sessionName: SSO session name
    @concurrent
    public func signOut(sessionName: String) async throws {
        try await self.performSignOut(sessionName: sessionName)
    }

    /// Actor-isolated body of sign-out. Called by the `@concurrent` wrapper.
    func performSignOut(sessionName: String) async throws {
        // Step 1: D21 cancel-then-queue — cancel in-flight refresh so its network call
        // unwinds quickly and the session lock becomes available without delay.
        inFlightRefresh[sessionName]?.cancel()
        cancelRefresh(forSession: sessionName)

        // Step 2: cancel in-flight sign-in and wait for it to unwind.
        // Done before taking the session lock so the sign-in lock entry drains first.
        if let task = inFlightTask(for: sessionName) {
            task.cancel()
            _ = try? await task.value
        }

        // Steps 3–8 run inside the session lock (D21) — serialized with any concurrent refresh
        // that was queued before we cancelled it. The cancel-then-queue above ensures the lock
        // becomes available quickly.
        try await withSessionLock(sessionName) {
            // Step 3: read token — idempotent if missing
            let token: StoredSSOToken
            do {
                token = try await self.keychain.readRecord(
                    StoredSSOToken.self,
                    service: ServiceConstants.ssoTokenService,
                    account: sessionName
                )
            } catch IAMIdentityCenterError.keychainItemMissing {
                // Already signed out
                self.eventContinuation.yield(.signedOut(sessionName: sessionName))
                return
            }

            // Step 4: cancel both timers
            await self.cancelExpiration(forSession: sessionName)
            // cancelRefresh already called in step 1; call again in case it was rescheduled
            await self.cancelRefresh(forSession: sessionName)

            // Step 5: emit signedOut — UI reacts before the network call
            self.eventContinuation.yield(.signedOut(sessionName: sessionName))

            // Step 6: delete the Keychain row
            try await self.keychain.deleteRecord(
                service: ServiceConstants.ssoTokenService,
                account: sessionName
            )

            // Step 7: fire Portal /logout best-effort
            // Use the URLSession injected at init time (tests inject StubURLProtocol.makeSession())
            let portalLogout = PortalLogout(urlSession: self.urlSession)
            do {
                try await portalLogout.logout(accessToken: token.accessToken, region: token.region)
            } catch {
                // Step 8: network failure — advisory event only, do not throw
                self.eventContinuation.yield(.signOutServerSideFailed(sessionName: sessionName))
            }
        }
    }
}
