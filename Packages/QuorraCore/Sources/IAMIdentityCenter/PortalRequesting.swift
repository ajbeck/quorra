import Foundation

/// Protocol over the SSO Portal wire operations (D23).
///
/// Exposes three verbs — `listAccounts`, `listAccountRoles`, `getRoleCredentials` — hiding
/// pagination internally. This allows tests to inject a verb-level stub instead of configuring
/// `URLProtocol` for tests that exercise actor behavior (not wire encoding).
///
/// `PortalClient` conforms via retroactive extension; `IdentityCenterService` holds
/// `any PortalRequesting`.
///
/// Mirrors `OIDCRequesting`'s seam shape (A2). Apple's documented pattern:
/// *"Replace complex dependencies with stubs… Adopting dependency injection and
/// protocol-oriented programming."* — Apple Testing documentation.
///
/// All verbs hit `portal.sso.<region>.amazonaws.com`. The bearer token is supplied
/// per-call (taken from `liveToken(forSession:)` at the call site) rather than baked
/// into the client — this keeps the Protocol stateless and the client reusable across
/// token rotations.
public protocol PortalRequesting: Sendable {
    /// Returns all accounts the authenticated user is assigned to.
    ///
    /// Pagination is handled internally — callers receive a flat array.
    func listAccounts(
        accessToken: String,
        region: String
    ) async throws -> [PortalAccount]

    /// Returns all roles the authenticated user can assume in the given account.
    ///
    /// Pagination is handled internally — callers receive a flat array.
    func listAccountRoles(
        accessToken: String,
        accountId: String,
        region: String
    ) async throws -> [PortalRole]

    /// Mints short-lived STS credentials for the given `(accountId, roleName)` pair.
    ///
    /// Returns a `MintedCredential` containing only the wire-response fields. The caller is
    /// responsible for attaching provenance (`accountId`, `roleName`, `region`, `sessionName`,
    /// `issuedAt`) when constructing the persisted `RoleCredentials` record.
    ///
    /// - Throws: `.roleNotAssigned` on `ForbiddenException`, `.accountNotFound` on
    ///   `ResourceNotFoundException`, `.network` on transport failure, `.httpStatus` on 5xx.
    func getRoleCredentials(
        accessToken: String,
        accountId: String,
        roleName: String,
        region: String
    ) async throws -> MintedCredential
}

extension PortalClient: PortalRequesting {}
