import Foundation

extension IdentityCenterService {
    // MARK: - Expiration timer machinery (D8 / D19)

    /// Schedules a one-shot task that fires `.expired(sessionName:)` when `expiresAt` passes.
    ///
    /// Cancels any existing expiration timer for the session before scheduling the new one.
    /// Delegates sleep to `sleeper.sleep(until:)` — production `WallClockSleeper` delegates
    /// to `Task.sleep(for:)` which uses `ContinuousClock` under the hood, so the timer fires
    /// correctly after a Mac wakes from sleep (D19). `MockSleeper` can advance synthetic time
    /// to any deadline in tests.
    func scheduleExpiration(forSession sessionName: String, expiresAt: Date) {
        expirationTimers[sessionName]?.cancel()

        let interval = expiresAt.timeIntervalSinceNow
        guard interval > 0 else {
            // Token is already expired — emit immediately
            eventContinuation.yield(.expired(sessionName: sessionName))
            return
        }

        expirationTimers[sessionName] = Task { [weak self] in
            do {
                // D19: delegate to the injected Sleeper so tests can advance time deterministically
                try await self?.sleeper.sleep(until: expiresAt)
            } catch {
                return  // cancelled; do not fire
            }
            await self?.handleExpiration(sessionName: sessionName)
        }
    }

    /// Cancels the expiration timer for `sessionName` (called on sign-out or refresh success).
    func cancelExpiration(forSession sessionName: String) {
        expirationTimers[sessionName]?.cancel()
        expirationTimers[sessionName] = nil
    }

    /// Called by the expiration task when the deadline fires.
    private func handleExpiration(sessionName: String) {
        expirationTimers[sessionName] = nil
        eventContinuation.yield(.expired(sessionName: sessionName))
    }

    // MARK: - Refresh timer machinery (D11 / A2)

    /// Schedules a one-shot task that triggers a silent refresh at `expiresAt − refreshSkew`.
    ///
    /// Mirrors the expiration-timer machinery. Only called when `canRefresh: true` (i.e. a
    /// refresh token exists in the Keychain).
    ///
    /// On refresh success: both timers are cancelled and rescheduled for the new `expiresAt`.
    /// On terminal failure: this timer is cancelled; `T_expire` runs to expiry.
    /// On transient failure: this timer is cancelled; `T_expire` runs to expiry; user can retry.
    func scheduleRefresh(forSession sessionName: String, expiresAt: Date) {
        refreshTimers[sessionName]?.cancel()

        let skew = ServiceConstants.refreshSkew
        let refreshDeadline = expiresAt.addingTimeInterval(-skew)
        let interval = refreshDeadline.timeIntervalSinceNow

        if interval <= 0 {
            // Already inside the skew window — trigger inline refresh immediately.
            // Guard on inFlightRefresh to avoid double-fire if liveToken already started one.
            Task { [weak self] in
                await self?.handleRefresh(sessionName: sessionName)
            }
            return
        }

        refreshTimers[sessionName] = Task { [weak self] in
            do {
                // D19: delegate to sleeper for test-determinism
                try await self?.sleeper.sleep(until: refreshDeadline)
            } catch {
                return  // cancelled; do not fire
            }
            await self?.handleRefresh(sessionName: sessionName)
        }
    }

    /// Cancels the refresh timer for `sessionName`.
    func cancelRefresh(forSession sessionName: String) {
        refreshTimers[sessionName]?.cancel()
        refreshTimers[sessionName] = nil
    }

    /// Called by the refresh timer when the deadline fires. Routes to `runRefresh` via the
    /// single-flight `inFlightRefresh` guard (D12 / D20 scenario: T_refresh fires during refresh).
    func handleRefresh(sessionName: String) async {
        refreshTimers[sessionName] = nil

        // D20: if a refresh is already in flight for this session (e.g. `liveToken` triggered
        // one inline), this timer fired redundantly — no-op.
        guard inFlightRefresh[sessionName] == nil else { return }

        await performRunRefresh(sessionName: sessionName)
    }
}
