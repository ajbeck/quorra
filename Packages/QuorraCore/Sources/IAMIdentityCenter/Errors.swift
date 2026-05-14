import Foundation

/// All errors that can be thrown by `IAMIdentityCenter` operations.
///
/// Uses Swift 6.2 untyped throws per TSPL §"Specifying the Error Type": most Swift code doesn't specify the type for the errors it throws.
public enum IAMIdentityCenterError: Error, Equatable, Sendable {
    // MARK: - Network & Transport

    /// URLSession-level transport error.
    case network(URLError)

    /// JSON decode failed or missing required fields.
    case malformedResponse(String)

    /// Unexpected HTTP status with no parseable AWS error envelope.
    case httpStatus(Int, body: String?)

    // MARK: - Device Flow (RFC 8628)

    /// User hasn't completed browser step yet (internal — absorbed by polling loop).
    case authorizationPending

    /// Server requests slower polling (internal — loop adds 5s to interval).
    case slowDown

    /// User refused at the IdP.
    case accessDenied

    /// Device code expired before user completed flow.
    case expiredDeviceCode

    /// Grant or device code is malformed (programmer error).
    case invalidGrant

    /// OIDC client registration is gone or expired.
    case invalidClient

    // MARK: - User Actions

    /// User pressed Cancel in the sign-in panel.
    case userCancelled

    /// Wall clock since StartDeviceAuthorization exceeded expiresIn.
    case deviceFlowTimedOut

    /// Another sign-in is already in flight for this session.
    case signInAlreadyInProgress(sessionName: String)

    // MARK: - AWS Service

    /// Forward-compat fallback for AWS error codes we don't have a typed case for.
    case awsError(code: String, description: String?)

    // MARK: - Keychain

    /// Expected Keychain row not present.
    case keychainItemMissing(service: String, account: String)

    /// Keychain operation failed at the OS level.
    case keychainStatus(OSStatus)

    /// Stored payload didn't decode (e.g. partial-write recovery).
    case keychainMalformed(reason: String)
}
