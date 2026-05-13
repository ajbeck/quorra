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
public protocol IdentityCenterServicing: Sendable {
    func signIn(
        sessionName: String,
        startUrl: URL,
        region: String,
        scopes: [String],
        clientName: String,
        verificationHandler: @escaping @Sendable (DeviceVerification) async -> Void
    ) async throws -> StoredSSOToken

    func cancelSignIn(sessionName: String) async
}
