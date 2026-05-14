import Foundation

/// Protocol surface of `IdentityCenterService`, exposed for testability.
///
/// Production code constructs the actor directly. Tests inject a conforming stub via
/// `CredentialsModel.init(service:)`.
///
/// Note for stub authors: under Swift 6.2's approachable-concurrency defaults, conforming
/// types must annotate `signIn` with `@concurrent` and the `verificationHandler` parameter
/// with `@escaping @concurrent @Sendable` — otherwise the inferred isolation
/// (`nonisolated(nonsending)`) won't match the protocol's `@concurrent` requirement.
///
/// The same `@concurrent` annotation applies to `status` and `signOut`. The `events` property
/// is `nonisolated` on the actor (stored at init time), so stubs should declare it as
/// `nonisolated var`.
public protocol IdentityCenterServicing: Sendable {
    // MARK: - Scope 1

    func signIn(
        sessionName: String,
        startUrl: URL,
        region: String,
        scopes: [String],
        clientName: String,
        verificationHandler: @escaping @Sendable (DeviceVerification) async -> Void
    ) async throws -> StoredSSOToken

    func cancelSignIn(sessionName: String) async

    // MARK: - A1 additions

    /// Returns the current authentication status for `sessionName`.
    ///
    /// Reads from the Keychain on every call (no actor-side cache per D6). Keychain errors
    /// are absorbed: `keychainItemMissing` and `keychainMalformed` both map to `.signedOut`
    /// per D7. Never throws.
    @concurrent
    func status(forSession sessionName: String) async -> SessionAuthStatus

    /// Signs out the session identified by `sessionName`.
    ///
    /// Order of operations per D3:
    /// 1. Cancel any in-flight sign-in for this session.
    /// 2. Read token from Keychain; if missing, emit `.signedOut` and return (idempotent).
    /// 3. Emit `.signedOut(sessionName:)` — UI flips immediately.
    /// 4. Delete the SSO token Keychain row.
    /// 5. Fire `POST /logout` to the Portal (best-effort).
    /// 6. On network failure: emit `.signOutServerSideFailed(sessionName:)` — do NOT throw.
    @concurrent
    func signOut(sessionName: String) async throws

    /// Shared stream of `AuthEvent`s emitted by this service instance.
    ///
    /// **Single-consumer contract:** `AsyncStream.Iterator` is not `Sendable`. Only one
    /// consumer should iterate this stream. The production consumer is `CredentialsModel`'s
    /// init-time Task. Declare `nonisolated` in conformers.
    nonisolated var events: AsyncStream<AuthEvent> { get }
}
