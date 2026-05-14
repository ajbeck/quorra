import Foundation

extension IdentityCenterService {
    // MARK: - Expiration timer machinery (D8)

    /// Schedules a one-shot task that fires `.expired(sessionName:)` when `expiresAt` passes.
    ///
    /// Cancels any existing timer for the session before scheduling the new one.
    /// Uses `ContinuousClock` (wall-clock time, does not stop while system sleeps) so the timer
    /// fires correctly after the Mac wakes from sleep. Apple: Swift/Task/sleep(until:tolerance:clock:)
    func scheduleExpiration(forSession sessionName: String, expiresAt: Date) {
        expirationTimers[sessionName]?.cancel()

        let interval = expiresAt.timeIntervalSinceNow
        guard interval > 0 else {
            // Token is already expired — emit immediately
            eventContinuation.yield(.expired(sessionName: sessionName))
            return
        }

        // Apple: Swift/ContinuousClock — measures time that always increments and does not
        // stop incrementing while the system is asleep. Correct for wall-clock token expiry.
        let deadline = ContinuousClock.now + .seconds(interval)

        expirationTimers[sessionName] = Task { [weak self] in
            do {
                // Apple: Swift/Task/sleep(until:tolerance:clock:) — throws CancellationError if cancelled
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch {
                return  // cancelled; do not fire
            }
            await self?.handleExpiration(sessionName: sessionName)
        }
    }

    /// Cancels the expiration timer for `sessionName` (called on sign-out).
    func cancelExpiration(forSession sessionName: String) {
        expirationTimers[sessionName]?.cancel()
        expirationTimers[sessionName] = nil
    }

    /// Called by the expiration task when the deadline fires.
    private func handleExpiration(sessionName: String) {
        expirationTimers[sessionName] = nil
        eventContinuation.yield(.expired(sessionName: sessionName))
    }
}
