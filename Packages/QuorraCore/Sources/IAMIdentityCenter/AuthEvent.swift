import Foundation

/// Domain events emitted by `IdentityCenterService` over its `events` stream.
///
/// `CredentialsModel` consumes the stream and re-pulls `status(forSession:)` on each event.
/// Events carry only `sessionName`; the model always re-reads full status from the actor.
///
/// **D2 + D8:** A1 cases are fully implemented. A2 cases (`refreshing`, `refreshed`,
/// `refreshFailed`) are declared so protocol conformers and stubs can be extended without
/// a breaking change when A2 ships.
public enum AuthEvent: Sendable, Hashable {
    // MARK: - A1 events

    /// Sign-in device-flow started (verificationHandler about to be called).
    case signInStarted(sessionName: String)

    /// Sign-in completed successfully; token persisted in Keychain.
    case signedIn(sessionName: String)

    /// In-flight sign-in was cancelled by the user.
    case signInCancelled(sessionName: String)

    /// Sign-in failed with an error.
    case signInFailed(sessionName: String)

    /// Local sign-out succeeded (Keychain row deleted). Portal /logout may or may not have
    /// succeeded; see `signOutServerSideFailed` for the network-failure case.
    case signedOut(sessionName: String)

    /// Wall-clock crossed `expiresAt` with no active refresh; status is now `expired`.
    case expired(sessionName: String)

    /// Local sign-out succeeded but the Portal /logout network call failed.
    /// Status is already `signedOut`; the model surfaces a soft advisory to the user.
    case signOutServerSideFailed(sessionName: String)

    // MARK: - A2 events (placeholder — produced by Scope A2's refresh logic)

    /// Silent refresh started in background.
    case refreshing(sessionName: String)

    /// Silent refresh completed; new token persisted in Keychain.
    case refreshed(sessionName: String)

    /// Silent refresh failed; status transitions to `expired(canRefresh: false)` if
    /// no further retry is possible.
    case refreshFailed(sessionName: String)

    // MARK: - B events (D30 — produced by role-credential mint paths)

    /// Role-credential mint started (inline or timer-fired). Emitted immediately before the
    /// `GetRoleCredentials` Portal call; bearer is already in hand.
    case mintingCredentials(sessionName: String, accountId: String, roleName: String)

    /// Role-credential mint succeeded; new credentials persisted in Keychain.
    case mintedCredentials(sessionName: String, accountId: String, roleName: String)

    /// Role-credential mint failed transiently (network/5xx). No Keychain mutation.
    /// The next `liveCredentials` call will retry.
    case mintCredentialsFailed(sessionName: String, accountId: String, roleName: String)

    /// Role access denied — the Portal returned `ForbiddenException` or
    /// `ResourceNotFoundException` (both are terminal: the tuple's cached row has been purged).
    /// The specific AWS error is preserved in the thrown `IAMIdentityCenterError` for diagnostics.
    case roleAccessDenied(sessionName: String, accountId: String, roleName: String)
}
