import Foundation

/// Factory for region-correct OIDC clients.
///
/// `IdentityCenterService` never holds a client directly; it asks the provider for one
/// keyed by region every time it makes a call. This decouples client construction
/// (region-bound by SDK config) from the actor's lifecycle (region-agnostic), and is the
/// single seam that fixes the previous bug where a fixed-region client rejected sign-ins
/// for sessions in any other region with `invalid_request: Invalid start url provided`.
public protocol OIDCClientProviding: Sendable {
    /// Returns an `OIDCRequesting` configured for the given AWS region.
    ///
    /// Implementations may cache per-region instances; callers must not assume identity
    /// across calls.
    func client(forRegion region: String) async throws -> any OIDCRequesting
}
