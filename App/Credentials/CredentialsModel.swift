import Foundation
import Observation
import IAMIdentityCenter

/// Observable presenter for IAM Identity Center sign-in and auth-status state.
///
/// Wraps the actor's flows with UI-friendly state:
/// - `status`: cached `SessionAuthStatus` per session (primary source of truth for views)
/// - `signOutFailure`: sessions where /logout failed (soft advisory)
/// - `refreshingNow`: sessions with an active silent refresh in flight (D17, A2)
/// - `refreshFailure`: sessions that had a transient refresh failure (D16, A2)
/// - `inFlight`: in-flight device-flow progress (for the inProgress panel mode)
/// - `lastError`: last sign-in error per session
///
/// A long-lived stream consumer Task started at init iterates the service's `events` stream
/// and re-pulls `status(forSession:)` for the affected session on every event. Views never
/// see the stream directly (D7).
///
/// All public mutations go through MainActor methods.
@Observable
@MainActor
final class CredentialsModel {
    // MARK: - Observed state

    /// Cached auth status per session name. Primary source of truth for sidebar icon + panel mode.
    private(set) var status: [String: SessionAuthStatus] = [:]

    /// Sessions for which the Portal /logout network call failed.
    /// Drives the soft advisory copy in `SignInPanel`'s `needsAction` mode.
    private(set) var signOutFailure: Set<String> = []

    /// Sessions with an active silent refresh in flight (D17).
    /// Drives the `isRefreshing` overlay on `SessionStatusIcon` and the "refreshing" caption in `SignInPanel`.
    /// Populated on `.refreshing`, cleared on `.refreshed` / `.refreshFailed`.
    private(set) var refreshingNow: Set<String> = []

    /// Sessions that had a transient refresh failure (D16).
    /// Drives the "Couldn't refresh your session. [Refresh now]" advisory in `SignInPanel`.
    /// Populated on `.refreshFailed`, cleared on `.refreshed` / next `.signedIn` / `.signedOut`.
    private(set) var refreshFailure: Set<String> = []

    /// In-flight device-flow progress per session (for the `inProgress` panel mode).
    private(set) var inFlight: [String: SignInProgress] = [:]

    /// Last sign-in error per session.
    private(set) var lastError: [String: IAMIdentityCenterError] = [:]

    // MARK: - Private stored

    @ObservationIgnored private let service: any IdentityCenterServicing

    /// Long-lived task that consumes `service.events` and refreshes status on each event.
    /// Held as `@ObservationIgnored` — not itself observable. Captured `[weak self]` so model
    /// deallocation unwinds the loop naturally on the next event.
    @ObservationIgnored private var eventConsumerTask: Task<Void, Never>?

    // MARK: - Init

    init(service: any IdentityCenterServicing) {
        self.service = service
        // Start the stream consumer Task. Captures [weak self] — if the model deallocates,
        // the guard-let at the top of the loop causes the task to exit naturally (D7).
        let events = service.events
        eventConsumerTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handleEvent(event)
            }
        }
    }

    // MARK: - Public API

    /// Drives sign-in for the given SSO session.
    ///
    /// Clears any prior `signOutFailure`, `refreshFailure`, and `lastError` for the session
    /// before starting. On the verificationHandler callback, populates `inFlight[sessionName]`.
    /// On success or failure, the event stream consumer updates `status` asynchronously.
    func signIn(
        sessionName: String,
        startUrl: URL,
        region: String,
        scopes: [String]
    ) async {
        // Clear stale state — guard against false invalidation on no-op assignment
        if lastError[sessionName] != nil { lastError[sessionName] = nil }
        if signOutFailure.contains(sessionName) { signOutFailure.remove(sessionName) }
        if refreshFailure.contains(sessionName) { refreshFailure.remove(sessionName) }

        do {
            _ = try await service.signIn(
                sessionName: sessionName,
                startUrl: startUrl,
                region: region,
                scopes: scopes,
                clientName: "Quorra",
                verificationHandler: { [weak self] verification in
                    guard let self else { return }
                    await self.recordVerification(sessionName: sessionName, verification: verification)
                }
            )
            if inFlight[sessionName] != nil { inFlight[sessionName] = nil }
        } catch let error as IAMIdentityCenterError {
            if inFlight[sessionName] != nil { inFlight[sessionName] = nil }
            if error != .userCancelled {
                lastError[sessionName] = error
            }
        } catch {
            if inFlight[sessionName] != nil { inFlight[sessionName] = nil }
            lastError[sessionName] = .malformedResponse(String(reflecting: error))
        }
    }

    /// Cancels an in-flight sign-in. The corresponding `signIn(...)` call will throw `.userCancelled`.
    func cancelSignIn(sessionName: String) async {
        await service.cancelSignIn(sessionName: sessionName)
    }

    /// Signs out the given session. Delegates to the service actor; results surface via the event stream.
    func signOut(sessionName: String) async {
        do {
            try await service.signOut(sessionName: sessionName)
        } catch {
            // signOut is documented to not throw under normal operation. If it does, treat as
            // a status-clearing no-op and log (production should not reach here).
        }
    }

    /// Triggers a programmatic refresh for the named session (D16).
    ///
    /// Called by the "Refresh now" button in `SignInPanel`'s transient-failure advisory.
    /// Clears `refreshFailure` before attempting so the UI returns to neutral immediately.
    func refreshNow(sessionName: String) async {
        // Optimistically clear the failure advisory — the new attempt will either succeed
        // (refreshed event clears refreshingNow) or fail again (refreshFailed event re-sets it).
        if refreshFailure.contains(sessionName) { refreshFailure.remove(sessionName) }

        do {
            _ = try await service.refreshNow(sessionName: sessionName)
        } catch {
            // Failure surfaces via the .refreshFailed event; nothing to do here.
        }
    }

    /// Populates `status[sessionName]` from the actor. Called by `SessionRow.task(id:)`.
    ///
    /// Per D6: each visible SessionRow calls this once; the stream consumer Task handles
    /// subsequent updates. Skips the Keychain hop when a cached value already exists —
    /// the event stream owns invalidation, so a re-appear without an intervening event
    /// is guaranteed to see the same status.
    func observeStatus(forSession sessionName: String) async {
        if status[sessionName] != nil { return }
        let s = await service.status(forSession: sessionName)
        if status[sessionName] != s {
            status[sessionName] = s
        }
    }

    // MARK: - Private

    /// Reacts to an `AuthEvent` from the service. Runs on MainActor.
    private func handleEvent(_ event: AuthEvent) async {
        switch event {
        case .signInStarted(let name):
            // Status will flip to .signingIn — re-pull from actor
            await refreshStatus(for: name)

        case .signedIn(let name):
            if inFlight[name] != nil { inFlight[name] = nil }
            // Clear sign-out advisory and refresh failure on successful re-sign-in
            if signOutFailure.contains(name) { signOutFailure.remove(name) }
            if refreshFailure.contains(name) { refreshFailure.remove(name) }
            if refreshingNow.contains(name) { refreshingNow.remove(name) }
            await refreshStatus(for: name)

        case .signInCancelled(let name):
            if inFlight[name] != nil { inFlight[name] = nil }
            await refreshStatus(for: name)

        case .signInFailed(let name):
            if inFlight[name] != nil { inFlight[name] = nil }
            await refreshStatus(for: name)

        case .signedOut(let name):
            if signOutFailure.contains(name) { signOutFailure.remove(name) }
            if refreshFailure.contains(name) { refreshFailure.remove(name) }
            if refreshingNow.contains(name) { refreshingNow.remove(name) }
            await refreshStatus(for: name)

        case .expired(let name):
            await refreshStatus(for: name)

        case .signOutServerSideFailed(let name):
            signOutFailure.insert(name)

        case .refreshing(let name):
            // D17: populate the refreshingNow overlay; status stays signedIn
            refreshingNow.insert(name)
            // Still re-pull status in case Keychain was updated between events
            await refreshStatus(for: name)

        case .refreshed(let name):
            // Clear both overlays; re-pull status (new token's expiresAt)
            if refreshingNow.contains(name) { refreshingNow.remove(name) }
            if refreshFailure.contains(name) { refreshFailure.remove(name) }
            await refreshStatus(for: name)

        case .refreshFailed(let name):
            // D17: clear refreshingNow; D16: set refreshFailure for transient advisory
            if refreshingNow.contains(name) { refreshingNow.remove(name) }
            refreshFailure.insert(name)
            await refreshStatus(for: name)
        }
    }

    /// Re-pulls status from the actor and updates the cache.
    private func refreshStatus(for sessionName: String) async {
        let s = await service.status(forSession: sessionName)
        if status[sessionName] != s {
            status[sessionName] = s
        }
    }

    /// Verification-handler callback. MainActor-isolated mutation hop required because the actor's
    /// callback runs in the actor's isolation, not the MainActor's.
    private func recordVerification(sessionName: String, verification: DeviceVerification) {
        let progress = SignInProgress(sessionName: sessionName, verification: verification)
        inFlight[sessionName] = progress
    }

    // MARK: - DEBUG test seams

    #if DEBUG
    /// Test seam: write-access to `lastError` for setting up "prior failure" preconditions.
    func seedLastErrorForTesting(_ error: IAMIdentityCenterError, sessionName: String) {
        lastError[sessionName] = error
    }

    /// Test seam: write-access to `inFlight` for setting up "signing in" preconditions.
    func seedInFlightForTesting(_ progress: SignInProgress, sessionName: String) {
        inFlight[sessionName] = progress
    }

    /// Test seam: write-access to `status` for setting up preconditions.
    func seedStatusForTesting(_ authStatus: SessionAuthStatus, sessionName: String) {
        status[sessionName] = authStatus
    }

    /// Test seam: write-access to `signOutFailure` for setting up advisory preconditions.
    func seedSignOutFailureForTesting(sessionName: String) {
        signOutFailure.insert(sessionName)
    }

    /// Test seam: write-access to `refreshingNow` for setting up refreshing-overlay preconditions.
    func seedRefreshingNowForTesting(sessionName: String) {
        refreshingNow.insert(sessionName)
    }

    /// Test seam: write-access to `refreshFailure` for setting up refresh-failure advisory preconditions.
    func seedRefreshFailureForTesting(sessionName: String) {
        refreshFailure.insert(sessionName)
    }
    #endif
}
