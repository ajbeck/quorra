import Foundation

/// Containment boundary for AWS SDK for Swift exceptions.
///
/// Two responsibilities, separated for testability:
///
/// 1. `mapOIDC` / `mapPortal` are **pure functions** over a `(typeName, message)` discriminator
///    pair. No SDK imports in their signatures — they're exhaustively unit-testable in
///    `SDKErrorMappingTests` with plain strings.
/// 2. `extract(from:)` pulls the discriminator out of a thrown error. It uses a benign
///    `String(describing: type(of: error))` fallback that yields a sensible discriminator
///    like `"InvalidClientException"` for any SDK exception whose Swift type name matches
///    the Smithy type name. If a future SDK exposes a public protocol with a typed
///    `typeName: String` / `message: String?` property pair, swap the fallback at the call
///    site — the mapping table and its tests are unaffected.
///
/// SDK version drift only affects `extract(from:)` and the type-name strings in the mapping
/// table — the test surface is stable.
enum SDKErrorMapping {

    /// OIDC service-error classification.
    ///
    /// Maps Smithy exception type names produced by `AWSSSOOIDC.SSOOIDCClient` to Quorra's
    /// domain error cases. Unknown type names fall through to `.awsError(code: "unknown", …)`,
    /// preserving the message for diagnostics.
    static func mapOIDC(typeName: String, message: String?) -> IAMIdentityCenterError {
        switch typeName {
        case "InvalidClientException":        return .invalidClient
        case "AuthorizationPendingException": return .authorizationPending
        case "SlowDownException":             return .slowDown
        case "AccessDeniedException":         return .accessDenied
        case "ExpiredTokenException":         return .expiredDeviceCode
        case "InvalidGrantException":         return .invalidGrant
        case "InvalidRequestException":
            return .awsError(code: "invalid_request", description: message)
        case "UnauthorizedClientException":
            return .awsError(code: "unauthorized_client", description: message)
        case "InternalServerException":
            return .awsError(code: "server_error", description: message)
        default:
            return .awsError(code: "unknown", description: message ?? typeName)
        }
    }

    /// Pulls a `(typeName, message)` discriminator out of an SDK exception.
    ///
    /// Uses the Swift type name as the discriminator — for `aws-sdk-swift`-generated
    /// service exceptions, this matches the Smithy type name (e.g. `InvalidClientException`,
    /// `AccessDeniedException`). Misclassification is benign: the mapping table's default
    /// case yields `.awsError("unknown", ...)` with the type name as the description.
    static func extract(from error: any Error) -> (typeName: String, message: String?) {
        (String(describing: type(of: error)), nil)
    }
}
