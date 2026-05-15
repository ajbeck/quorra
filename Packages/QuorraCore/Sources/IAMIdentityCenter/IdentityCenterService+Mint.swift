import Foundation
import OSLog

private let mintTimerLogger = Logger(subsystem: "dev.ajbeck.quorra", category: "IAMIdentityCenter.MintTimer")

extension IdentityCenterService {
    // MARK: - Mint timer machinery (D28)

    /// Schedules a one-shot task that fires a proactive mint at `expiresAt − refreshSkew`.
    ///
    /// Cancels any existing mint timer for the tuple before scheduling a new one. Mirrors
    /// `scheduleRefresh` in Expiration.swift — same structure, same `Sleeper.sleep(until:)`
    /// delegation, same immediate-fire guard for the case where `expiresAt` is already inside
    /// the skew window.
    ///
    /// Called from `runMintBody`'s success path after a credential is written to the Keychain,
    /// so the next proactive mint fires at the new credential's deadline (D28 scheduling trigger
    /// "on successful mint").
    ///
    /// Apple: Swift/Task — `[weak self]` capture prevents a reference cycle between the actor
    /// and the fire-and-forget timer Task. Actor isolation ensures mutations to `mintTimers`
    /// are safe.
    func scheduleMint(
        forSession sessionName: String,
        accountId: String,
        roleName: String,
        region: String,
        expiresAt: Date
    ) {
        let key = "\(sessionName):\(accountId):\(roleName)"
        mintTimers[key]?.cancel()

        let skew = ServiceConstants.refreshSkew
        let refreshDeadline = expiresAt.addingTimeInterval(-skew)
        let interval = refreshDeadline.timeIntervalSinceNow

        if interval <= 0 {
            // Already inside the skew window — trigger inline mint immediately.
            // Guard on inFlightMint to avoid double-fire if liveCredentials already started one.
            Task { [weak self] in
                await self?.handleMint(
                    sessionName: sessionName,
                    accountId: accountId,
                    roleName: roleName,
                    region: region,
                    key: key
                )
            }
            return
        }

        mintTimers[key] = Task { [weak self] in
            do {
                // D19: delegate to sleeper for test-determinism; production WallClockSleeper
                // delegates to Task.sleep(for:) which uses ContinuousClock internally, so the
                // timer fires correctly after a Mac wakes from sleep.
                try await self?.sleeper.sleep(until: refreshDeadline)
            } catch {
                return  // cancelled; do not fire
            }
            await self?.handleMint(
                sessionName: sessionName,
                accountId: accountId,
                roleName: roleName,
                region: region,
                key: key
            )
        }
    }

    /// Cancels the mint timer for the given `(session, account, role)` tuple.
    ///
    /// Called by the sign-out cascade (D27, chunk 5) for every timer whose key starts with
    /// `<sessionName>:`. Also available for direct cancellation in tests.
    func cancelMint(forSession sessionName: String, accountId: String, roleName: String) {
        let key = "\(sessionName):\(accountId):\(roleName)"
        mintTimers[key]?.cancel()
        mintTimers[key] = nil
    }

    /// Cancels the mint timer identified by a pre-computed key (sign-out cascade convenience).
    func cancelMint(forKey key: String) {
        mintTimers[key]?.cancel()
        mintTimers[key] = nil
    }

    /// Called by the mint timer when the deadline fires.
    ///
    /// Clears its own slot in `mintTimers`, then performs a defensive guard before doing any
    /// work: if `inFlightMint[key]` is already populated, a `liveCredentials` inline mint is
    /// already running — the timer fired redundantly — no-op, mirroring A2's `handleRefresh`
    /// guard on `inFlightRefresh` (D20). Otherwise routes through `startInlineMint` so the
    /// single-flight guarantee and provenance construction stay in one place (chunk 2 / D26).
    ///
    /// This path is fire-and-forget: errors are swallowed. A transient failure here just means
    /// the next `liveCredentials` call lazy-mints instead (D28: "on transient failure, leave
    /// the timer slot empty; rely on lazy mint").
    func handleMint(
        sessionName: String,
        accountId: String,
        roleName: String,
        region: String,
        key: String
    ) async {
        mintTimers[key] = nil

        // D28 defensive guard: if liveCredentials already has a mint in flight for this tuple,
        // the timer fired redundantly — no-op. Mirrors A2 handleRefresh's inFlightRefresh guard.
        guard inFlightMint[key] == nil else {
            mintTimerLogger.debug("T_mint no-op: inFlightMint already set for key \(key)")
            return
        }

        mintTimerLogger.debug("T_mint firing proactive mint for key \(key)")

        // Route through startInlineMint so single-flight + provenance construction stay in
        // chunk-2's runMintBody — no parallel copy of that logic here.
        _ = try? await startInlineMint(
            sessionName: sessionName,
            accountId: accountId,
            roleName: roleName,
            region: region,
            key: key
        )
        // Errors swallowed: a failed proactive mint is silent; the next liveCredentials call
        // lazy-mints on demand (D28 transient-failure behaviour).
    }
}
