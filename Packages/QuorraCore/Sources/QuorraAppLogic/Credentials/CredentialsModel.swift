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
/// - `profileStatus`: cached `ProfileAuthStatus` per `"<sessionName>:<accountId>:<roleName>"` key (D30, B)
/// - `mintingNow`: tuples with an active credential mint in flight (D30, B)
/// - `mintFailure`: tuples that had a transient mint failure (D30, B)
/// - `roleRejected`: tuples where a terminal access-denied error was received (D30, B)
///
/// A long-lived stream consumer Task started at init iterates the service's `events` stream
/// and re-pulls `status(forSession:)` for the affected session on every event. Views never
/// see the stream directly (D7).
///
/// All public mutations go through MainActor methods.
@Observable
@MainActor
public final class CredentialsModel {
    // MARK: - Observed state

    /// Cached auth status per session name. Primary source of truth for sidebar icon + panel mode.
    public private(set) var status: [String: SessionAuthStatus] = [:]

    /// Sessions for which the Portal /logout network call failed.
    /// Drives the soft advisory copy in `SignInPanel`'s `needsAction` mode.
    public private(set) var signOutFailure: Set<String> = []

    /// Sessions with an active silent refresh in flight (D17).
    /// Drives the `isRefreshing` overlay on `SessionStatusIcon` and the "refreshing" caption in `SignInPanel`.
    /// Populated on `.refreshing`, cleared on `.refreshed` / `.refreshFailed`.
    public private(set) var refreshingNow: Set<String> = []

    /// Sessions that had a transient refresh failure (D16).
    /// Drives the "Couldn't refresh your session. [Refresh now]" advisory in `SignInPanel`.
    /// Populated on `.refreshFailed`, cleared on `.refreshed` / next `.signedIn` / `.signedOut`.
    public private(set) var refreshFailure: Set<String> = []

    // MARK: - B overlay sets (D30)

    /// Cached `ProfileAuthStatus` per `"<sessionName>:<accountId>:<roleName>"` key.
    /// Populated on demand by `observeProfileStatus` and invalidated by mint events.
    public private(set) var profileStatus: [String: ProfileAuthStatus] = [:]

    /// Tuples with an active credential mint in flight.
    /// Keys are `"<sessionName>:<accountId>:<roleName>"`.
    /// Populated on `.mintingCredentials`, cleared on `.mintedCredentials` / `.mintCredentialsFailed` / `.roleAccessDenied`.
    public private(set) var mintingNow: Set<String> = []

    /// Tuples that had a transient mint failure.
    /// Keys are `"<sessionName>:<accountId>:<roleName>"`.
    /// Populated on `.mintCredentialsFailed`, cleared on `.mintingCredentials` / `.mintedCredentials`.
    public private(set) var mintFailure: Set<String> = []

    /// Tuples where role access was denied (terminal — `ForbiddenException` or `ResourceNotFoundException`).
    /// Keys are `"<sessionName>:<accountId>:<roleName>"`.
    /// Populated on `.roleAccessDenied`, cleared on `.mintingCredentials`.
    public private(set) var roleRejected: Set<String> = []

    /// In-flight device-flow progress per session (for the `inProgress` panel mode).
    public private(set) var inFlight: [String: SignInProgress] = [:]

    /// Last sign-in error per session.
    public private(set) var lastError: [String: IAMIdentityCenterError] = [:]

    // MARK: - Private stored

    @ObservationIgnored private let service: any IdentityCenterServicing

    /// Long-lived task that consumes `service.events` and refreshes status on each event.
    /// Held as `@ObservationIgnored` — not itself observable. Captured `[weak self]` so model
    /// deallocation unwinds the loop naturally on the next event.
    @ObservationIgnored private var eventConsumerTask: Task<Void, Never>?

    // MARK: - Init

    public init(service: any IdentityCenterServicing) {
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
    public func signIn(
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
    public func cancelSignIn(sessionName: String) async {
        await service.cancelSignIn(sessionName: sessionName)
    }

    /// Signs out the given session. Delegates to the service actor; results surface via the event stream.
    public func signOut(sessionName: String) async {
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
    public func refreshNow(sessionName: String) async {
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
    public func observeStatus(forSession sessionName: String) async {
        if status[sessionName] != nil { return }
        let s = await service.status(forSession: sessionName)
        if status[sessionName] != s {
            status[sessionName] = s
        }
    }

    /// Populates `profileStatus[key]` from the actor. Called by `ProfileRow.task(id:)`.
    ///
    /// Mirrors `observeStatus(forSession:)` exactly but for the `(sessionName, accountId, roleName)`
    /// tuple. Skips the actor hop when a cached value already exists — the event stream owns
    /// invalidation (D30). Key is `"<sessionName>:<accountId>:<roleName>"`.
    public func observeProfileStatus(forSession sessionName: String, accountId: String, roleName: String) async {
        let key = "\(sessionName):\(accountId):\(roleName)"
        if profileStatus[key] != nil { return }
        let s = await service.status(forProfile: sessionName, accountId: accountId, roleName: roleName)
        if profileStatus[key] != s {
            profileStatus[key] = s
        }
    }

    /// Fetches live role credentials for a profile tuple, forwarding to the actor's
    /// `liveCredentials` (D26 — returns cached if fresh, mints inline if stale/absent,
    /// single-flight coalesced). The returned `RoleCredentials` is intentionally NOT stored
    /// on the model: secret material is held only transiently in the calling view's `@State`
    /// and cleared when the credentials section collapses (D31 security posture). Mint
    /// progress/outcome still flows through the event stream into the overlay Sets.
    public func liveCredentials(
        forSession sessionName: String,
        accountId: String,
        roleName: String,
        region: String
    ) async throws -> RoleCredentials {
        try await service.liveCredentials(
            forSession: sessionName,
            accountId: accountId,
            roleName: roleName,
            region: region
        )
    }

    /// Forces a fresh role-credential mint for an explicit user renewal action.
    public func renewCredentials(
        forSession sessionName: String,
        accountId: String,
        roleName: String,
        region: String
    ) async throws -> RoleCredentials {
        try await service.renewCredentials(
            forSession: sessionName,
            accountId: accountId,
            roleName: roleName,
            region: region
        )
    }

    // MARK: - Private

    /// Reacts to an `AuthEvent` from the service. Runs on MainActor.
    private func handleEvent(_ event: AuthEvent) async {
        switch event {
        case .signInStarted(let name):
            // Status will flip to .signingIn — re-pull from actor
            await refreshStatusAndObservedProfiles(forSession: name)

        case .signedIn(let name):
            if inFlight[name] != nil { inFlight[name] = nil }
            // Clear sign-out advisory and refresh failure on successful re-sign-in
            if signOutFailure.contains(name) { signOutFailure.remove(name) }
            if refreshFailure.contains(name) { refreshFailure.remove(name) }
            if refreshingNow.contains(name) { refreshingNow.remove(name) }
            await refreshStatusAndObservedProfiles(forSession: name)

        case .signInCancelled(let name):
            if inFlight[name] != nil { inFlight[name] = nil }
            await refreshStatusAndObservedProfiles(forSession: name)

        case .signInFailed(let name):
            if inFlight[name] != nil { inFlight[name] = nil }
            await refreshStatusAndObservedProfiles(forSession: name)

        case .signedOut(let name):
            if signOutFailure.contains(name) { signOutFailure.remove(name) }
            if refreshFailure.contains(name) { refreshFailure.remove(name) }
            if refreshingNow.contains(name) { refreshingNow.remove(name) }
            // D30: clear all B overlay sets for every key that belongs to this session.
            // Keys have the form "<sessionName>:<accountId>:<roleName>"; prefix-match on "<name>:".
            let prefix = "\(name):"
            mintingNow = mintingNow.filter { !$0.hasPrefix(prefix) }
            mintFailure = mintFailure.filter { !$0.hasPrefix(prefix) }
            roleRejected = roleRejected.filter { !$0.hasPrefix(prefix) }
            markObservedProfileStatuses(forSession: name, as: .notSignedIn(sessionName: name))
            status[name] = .signedOut

        case .expired(let name):
            await refreshStatusAndObservedProfiles(forSession: name)

        case .signOutServerSideFailed(let name):
            signOutFailure.insert(name)

        case .refreshing(let name):
            // D17: populate the refreshingNow overlay; status stays signedIn
            refreshingNow.insert(name)
            // Still re-pull status in case Keychain was updated between events
            await refreshStatusAndObservedProfiles(forSession: name)

        case .refreshed(let name):
            // Clear both overlays; re-pull status (new token's expiresAt)
            if refreshingNow.contains(name) { refreshingNow.remove(name) }
            if refreshFailure.contains(name) { refreshFailure.remove(name) }
            await refreshStatusAndObservedProfiles(forSession: name)

        case .refreshFailed(let name):
            // D17: clear refreshingNow; D16: set refreshFailure for transient advisory
            if refreshingNow.contains(name) { refreshingNow.remove(name) }
            refreshFailure.insert(name)
            await refreshStatusAndObservedProfiles(forSession: name)

        // MARK: B events (D30)

        case .mintingCredentials(let session, let accountId, let role):
            let key = "\(session):\(accountId):\(role)"
            mintingNow.insert(key)
            if mintFailure.contains(key) { mintFailure.remove(key) }
            if roleRejected.contains(key) { roleRejected.remove(key) }
            await refreshProfileStatus(forSession: session, accountId: accountId, roleName: role)

        case .mintedCredentials(let session, let accountId, let role):
            let key = "\(session):\(accountId):\(role)"
            if mintingNow.contains(key) { mintingNow.remove(key) }
            if mintFailure.contains(key) { mintFailure.remove(key) }
            if roleRejected.contains(key) { roleRejected.remove(key) }
            await refreshProfileStatus(forSession: session, accountId: accountId, roleName: role)

        case .mintCredentialsFailed(let session, let accountId, let role):
            let key = "\(session):\(accountId):\(role)"
            if mintingNow.contains(key) { mintingNow.remove(key) }
            mintFailure.insert(key)
            // No profile status re-pull on transient failure — profile stays .ready; the overlay
            // Set drives the advisory. Matches D30's explicit mapping table.

        case .roleAccessDenied(let session, let accountId, let role):
            let key = "\(session):\(accountId):\(role)"
            if mintingNow.contains(key) { mintingNow.remove(key) }
            if mintFailure.contains(key) { mintFailure.remove(key) }
            roleRejected.insert(key)
            await refreshProfileStatus(forSession: session, accountId: accountId, roleName: role)
        }
    }

    /// Re-pulls status from the actor and updates the cache.
    private func refreshStatus(for sessionName: String) async {
        let s = await service.status(forSession: sessionName)
        if status[sessionName] != s {
            status[sessionName] = s
        }
    }

    /// Re-pulls both the session status and every already-observed profile status for that
    /// session. A session token transition changes the readiness of all role profiles under it,
    /// so the per-profile cache must move in lockstep with the session cache.
    private func refreshStatusAndObservedProfiles(forSession sessionName: String) async {
        await refreshStatus(for: sessionName)
        await refreshObservedProfileStatuses(forSession: sessionName)
    }

    /// Re-pulls every cached profile-status entry whose key belongs to `sessionName`.
    private func refreshObservedProfileStatuses(forSession sessionName: String) async {
        for profileKey in observedProfileKeys(forSession: sessionName) {
            let s = await service.status(
                forProfile: sessionName,
                accountId: profileKey.accountId,
                roleName: profileKey.roleName
            )
            if profileStatus[profileKey.key] != s {
                profileStatus[profileKey.key] = s
            }
        }
    }

    /// Writes a known profile status into every cached profile-status entry for `sessionName`.
    /// Used for sign-out because the sign-out event is intentionally emitted before Keychain
    /// deletion completes, so reading the actor immediately could momentarily see the old token.
    private func markObservedProfileStatuses(forSession sessionName: String, as newStatus: ProfileAuthStatus) {
        for profileKey in observedProfileKeys(forSession: sessionName) {
            if profileStatus[profileKey.key] != newStatus {
                profileStatus[profileKey.key] = newStatus
            }
        }
    }

    private func observedProfileKeys(forSession sessionName: String) -> [(key: String, accountId: String, roleName: String)] {
        let prefix = "\(sessionName):"
        return profileStatus.keys.compactMap { key in
            guard key.hasPrefix(prefix) else { return nil }
            let remainder = key.dropFirst(prefix.count)
            let parts = remainder.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return (key, String(parts[0]), String(parts[1]))
        }
    }

    /// Re-pulls `ProfileAuthStatus` from the actor and updates `profileStatus[key]`.
    /// Mirrors `refreshStatus(for:)` for the B overlay path (D30).
    private func refreshProfileStatus(forSession sessionName: String, accountId: String, roleName: String) async {
        let key = "\(sessionName):\(accountId):\(roleName)"
        let s = await service.status(forProfile: sessionName, accountId: accountId, roleName: roleName)
        if profileStatus[key] != s {
            profileStatus[key] = s
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
    /// Test seam: exercises event-to-state mapping without going through the AsyncStream
    /// consumer task, keeping event mapping tests deterministic and layer-local.
    func processEventForTesting(_ event: AuthEvent) async {
        await handleEvent(event)
    }

    /// Test seam: write-access to `lastError` for setting up "prior failure" preconditions.
    public func seedLastErrorForTesting(_ error: IAMIdentityCenterError, sessionName: String) {
        lastError[sessionName] = error
    }

    /// Test seam: write-access to `inFlight` for setting up "signing in" preconditions.
    public func seedInFlightForTesting(_ progress: SignInProgress, sessionName: String) {
        inFlight[sessionName] = progress
    }

    /// Test seam: write-access to `status` for setting up preconditions.
    public func seedStatusForTesting(_ authStatus: SessionAuthStatus, sessionName: String) {
        status[sessionName] = authStatus
    }

    /// Test seam: write-access to `signOutFailure` for setting up advisory preconditions.
    public func seedSignOutFailureForTesting(sessionName: String) {
        signOutFailure.insert(sessionName)
    }

    /// Test seam: write-access to `refreshingNow` for setting up refreshing-overlay preconditions.
    public func seedRefreshingNowForTesting(sessionName: String) {
        refreshingNow.insert(sessionName)
    }

    /// Test seam: write-access to `refreshFailure` for setting up refresh-failure advisory preconditions.
    public func seedRefreshFailureForTesting(sessionName: String) {
        refreshFailure.insert(sessionName)
    }

    /// Test seam: write-access to `mintingNow` for setting up minting-overlay preconditions.
    public func seedMintingNowForTesting(key: String) {
        mintingNow.insert(key)
    }

    /// Test seam: write-access to `mintFailure` for setting up mint-failure advisory preconditions.
    public func seedMintFailureForTesting(key: String) {
        mintFailure.insert(key)
    }

    /// Test seam: write-access to `roleRejected` for setting up role-rejected advisory preconditions.
    public func seedRoleRejectedForTesting(key: String) {
        roleRejected.insert(key)
    }

    /// Test seam: write-access to `profileStatus` for SwiftUI previews of the profile row /
    /// credentials reveal section. Key is `"<sessionName>:<accountId>:<roleName>"`.
    public func seedProfileStatusForTesting(_ status: ProfileAuthStatus, key: String) {
        profileStatus[key] = status
    }
    #endif
}
