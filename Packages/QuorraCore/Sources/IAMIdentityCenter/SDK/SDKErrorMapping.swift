import Foundation
import protocol ClientRuntime.ServiceError

/// Containment boundary for AWS SDK for Swift exceptions.
///
/// Two responsibilities, separated for testability:
///
/// 1. `mapOIDC` is a pure function over a `(typeName, message)` discriminator pair.
///    No SDK imports in its signature — it's exhaustively unit-testable in
///    `SDKErrorMappingTests` with plain strings.
/// 2. `extract(from:)` pulls the discriminator out of the SDK's public `ServiceError`
///    protocol, preserving the service message for diagnostics. It falls back to the
///    Swift type name for non-service errors.
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
        case "InvalidScopeException":
            return .awsError(code: "invalid_scope", description: message)
        case "UnsupportedGrantTypeException":
            return .awsError(code: "unsupported_grant_type", description: message)
        default:
            return .awsError(code: "unknown", description: message ?? typeName)
        }
    }

    /// Pulls a `(typeName, message)` discriminator out of an SDK exception.
    ///
    /// Uses the SDK's `ServiceError` protocol when available. Misclassification is benign:
    /// the mapping table's default case yields `.awsError("unknown", ...)` with the type
    /// name as the description.
    static func extract(from error: any Error) -> (typeName: String, message: String?) {
        if let serviceError = error as? any ServiceError {
            return (
                serviceError.typeName ?? String(describing: type(of: error)),
                serviceError.message
            )
        }
        return (String(describing: type(of: error)), nil)
    }
}
