import Foundation

extension IdentityCenterService {
    // MARK: - Sign-out flow (D3)

    /// Signs out the session identified by `sessionName`.
    ///
    /// `@concurrent` satisfies the protocol's isolation requirement; immediately hops to the
    /// actor's isolated context via `self.performSignOut(sessionName:)`.
    ///
    /// Order of operations per D3:
    /// 1. Cancel any in-flight sign-in for this session and wait for it to unwind.
    /// 2. Read the `StoredSSOToken` from Keychain. If missing, emit `.signedOut` and return (idempotent).
    /// 3. Cancel the expiration timer.
    /// 4. Emit `.signedOut(sessionName:)` — UI flips immediately.
    /// 5. Delete the SSO token Keychain row.
    /// 6. Fire `POST /logout` to the Portal (best-effort, injected URLSession for testability).
    /// 7. If step 6 fails: emit `.signOutServerSideFailed(sessionName:)` — do NOT throw.
    ///
    /// - Parameter sessionName: SSO session name
    @concurrent
    public func signOut(sessionName: String) async throws {
        try await self.performSignOut(sessionName: sessionName)
    }

    /// Actor-isolated body of sign-out. Called by the `@concurrent` wrapper.
    func performSignOut(sessionName: String) async throws {
        // Step 1: cancel in-flight sign-in and wait for it to unwind
        if let task = inFlightTask(for: sessionName) {
            task.cancel()
            _ = try? await task.value
        }

        // Step 2: read token — idempotent if missing
        let token: StoredSSOToken
        do {
            token = try await keychain.readRecord(
                StoredSSOToken.self,
                service: ServiceConstants.ssoTokenService,
                account: sessionName
            )
        } catch IAMIdentityCenterError.keychainItemMissing {
            // Already signed out
            eventContinuation.yield(.signedOut(sessionName: sessionName))
            return
        }

        // Step 3: cancel expiration timer
        cancelExpiration(forSession: sessionName)

        // Step 4: emit signedOut — UI reacts before the network call
        eventContinuation.yield(.signedOut(sessionName: sessionName))

        // Step 5: delete the Keychain row
        try await keychain.deleteRecord(
            service: ServiceConstants.ssoTokenService,
            account: sessionName
        )

        // Step 6: fire Portal /logout best-effort
        // Use the URLSession injected at init time (tests inject StubURLProtocol.makeSession())
        let portalLogout = PortalLogout(urlSession: urlSession)
        do {
            try await portalLogout.logout(accessToken: token.accessToken, region: token.region)
        } catch {
            // Step 7: network failure — advisory event only, do not throw
            eventContinuation.yield(.signOutServerSideFailed(sessionName: sessionName))
        }
    }
}
