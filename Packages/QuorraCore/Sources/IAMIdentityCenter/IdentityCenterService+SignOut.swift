import Foundation

extension IdentityCenterService {
    // MARK: - Sign-out flow (D3 / D21 / D27)

    /// Signs out the session identified by `sessionName`.
    ///
    /// `@concurrent` satisfies the protocol's isolation requirement; immediately hops to the
    /// actor's isolated context via `self.performSignOut(sessionName:)`.
    ///
    /// Order of operations per D3 + D21 + D27:
    ///  1. Cancel any in-flight refresh (cancel-then-queue per D21).
    ///     **D27 extension**: also cancel every `inFlightMint[key]` whose key starts with `"<sessionName>:"`.
    ///  2. Cancel any in-flight sign-in for this session and wait for it to unwind.
    ///  3. (Inside session lock) Read the `StoredSSOToken` from Keychain.
    ///  4. (Inside session lock) Cancel both timers (T_expire + T_refresh).
    ///     **D27 extension**: also cancel every `T_mint` whose key starts with `"<sessionName>:"`.
    ///  5. (Inside session lock) Emit `.signedOut(sessionName:)` — UI flips immediately.
    ///  6. (Inside session lock) If SSO token was missing, also purge role-cred rows then return (idempotent).
    ///  7. (Inside session lock) Delete the SSO token Keychain row.
    ///  8. (Inside session lock) **D27 extension**: enumerate role-cred rows under
    ///     `service: dev.ajbeck.quorra.role-creds` and delete every one whose account starts with
    ///     `"<sessionName>:"`. Runs on both the normal and idempotent-missing-token paths.
    ///  9. (Inside session lock) Fire `POST /logout` to the Portal (best-effort, injected URLSession).
    /// 10. If step 9 fails: emit `.signOutServerSideFailed(sessionName:)` — do NOT throw.
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

        // D27 extension to step 1: cancel every in-flight mint for this session.
        // The cancelled mint's network call unwinds with CancellationError; no Keychain write
        // happens — same rationale as the refresh cancel above (D26 single-flight coalescing
        // guarantees the waiter also gets CancellationError).
        // Snapshot keys before iterating to avoid mutate-while-iterating under Swift 6.
        // Apple: Swift/Task/cancel() — cooperative cancellation; safe to call from the actor context.
        for key in Array(inFlightMint.keys) where key.hasPrefix("\(sessionName):") {
            inFlightMint[key]?.cancel()
        }

        // Step 2: cancel in-flight sign-in and wait for it to unwind.
        // Done before taking the session lock so the sign-in lock entry drains first.
        if let task = inFlightTask(for: sessionName) {
            task.cancel()
            _ = try? await task.value
        }

        // Steps 3–10 run inside the session lock (D21) — serialized with any concurrent refresh
        // that was queued before we cancelled it. The cancel-then-queue above ensures the lock
        // becomes available quickly.
        try await withSessionLock(sessionName) {
            // Step 3: read token — capture result without an early return so the role-cred
            // purge (D27 security-critical ordering) can run on BOTH the normal and the
            // idempotent-missing-token paths. Missing key is normal (idempotent path);
            // any other Keychain error is unexpected and re-thrown.
            let tokenResult: StoredSSOToken?
            do {
                tokenResult = try await self.keychain.readRecord(
                    StoredSSOToken.self,
                    service: ServiceConstants.ssoTokenService,
                    account: sessionName
                )
            } catch IAMIdentityCenterError.keychainItemMissing {
                tokenResult = nil
            } catch {
                throw error
            }

            // Step 4: cancel both timers.
            // cancelRefresh already called in step 1; call again in case it was rescheduled.
            await self.cancelExpiration(forSession: sessionName)
            await self.cancelRefresh(forSession: sessionName)

            // D27 extension to step 4 (step 6 in D27 numbering): cancel every T_mint for
            // this session. Snapshot keys before iterating (Swift 6 mutate-while-iterating safety).
            // `await` crosses the actor boundary from this Sendable closure back to the actor.
            let mintTimerKeys = await self.mintTimers.keys.filter { $0.hasPrefix("\(sessionName):") }
            for key in mintTimerKeys {
                await self.cancelMint(forKey: key)
            }

            // Step 5: emit signedOut — UI reacts before any network call.
            self.eventContinuation.yield(.signedOut(sessionName: sessionName))

            // Step 8 / D27 step 9: purge role-cred rows for this session.
            // Runs unconditionally — before the idempotent early return and before /logout —
            // so a session that was already signed out can't leave orphaned role-cred rows
            // (the exact bug D27 prevents). Linear prefix scan is microseconds for <50 rows.
            // Apple: SecItemCopyMatching / enumerateAccounts returns unordered results; order
            // does not matter for delete.
            let roleCredAccounts = (try? await self.keychain.enumerateAccounts(
                service: ServiceConstants.roleCredsService
            )) ?? []
            for account in roleCredAccounts where account.hasPrefix("\(sessionName):") {
                try? await self.keychain.delete(
                    service: ServiceConstants.roleCredsService,
                    account: account
                )
            }

            // Step 6: idempotent early return when the SSO token was missing.
            // The role-cred purge above already ran so there are no orphaned rows.
            guard let token = tokenResult else {
                // Already signed out (or token was never written); .signedOut already emitted.
                return
            }

            // Step 7: delete the SSO token Keychain row.
            try await self.keychain.deleteRecord(
                service: ServiceConstants.ssoTokenService,
                account: sessionName
            )

            // Step 9: fire Portal /logout best-effort.
            // Use the URLSession injected at init time (tests inject StubURLProtocol.makeSession()).
            let portalLogout = PortalLogout(urlSession: self.urlSession)
            do {
                try await portalLogout.logout(accessToken: token.accessToken, region: token.region)
            } catch {
                // Step 10: network failure — advisory event only, do not throw.
                self.eventContinuation.yield(.signOutServerSideFailed(sessionName: sessionName))
            }
        }
    }
}
