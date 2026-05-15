import Foundation

extension IAMIdentityCenterError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .network(let urlError):
            return "Network error: \(urlError.localizedDescription)"

        case .malformedResponse(let reason):
            return "Server response could not be parsed: \(reason)"

        case .httpStatus(let code, let body):
            if let body = body {
                return "HTTP \(code): \(body)"
            } else {
                return "HTTP \(code)"
            }

        case .authorizationPending:
            return "Authorization pending."

        case .slowDown:
            return "Polling too fast."

        case .accessDenied:
            return "Access denied."

        case .expiredDeviceCode:
            return "Sign-in request expired. Please try again."

        case .invalidGrant:
            return "Invalid grant."

        case .invalidClient:
            return "Client registration expired. Please sign in again."

        case .userCancelled:
            return "Sign-in cancelled."

        case .deviceFlowTimedOut:
            return "Sign-in timed out. Please try again."

        case .signInAlreadyInProgress(let sessionName):
            return "A sign-in is already in progress for session \(sessionName)."

        case .awsError(let code, let description):
            if let description = description {
                return "AWS error \(code): \(description)"
            } else {
                return "AWS error \(code)"
            }

        case .keychainItemMissing(let service, let account):
            return "Keychain item missing for \(service)/\(account)."

        case .keychainStatus(let status):
            return "Keychain operation failed with status \(status)."

        case .keychainMalformed(let reason):
            return "Stored credential is corrupt: \(reason)"

        case .tokenExpired:
            return "Your session token has expired."

        case .notSignedIn:
            return "Not signed in to this session."

        case .refreshTokenRejected:
            return "Session refresh was rejected by AWS. Please sign in again."

        case .refreshClientInvalid:
            return "Client registration expired during refresh. Please sign in again."

        case .roleNotAssigned:
            return "This role is no longer assigned to your user. Contact your AWS administrator."

        case .accountNotFound:
            return "The AWS account could not be found. Check your profile configuration."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .network:
            return "Check your network connection and try again."

        case .expiredDeviceCode:
            return "Start a new sign-in attempt."

        case .invalidClient:
            return "Quorra will re-register automatically on your next sign-in."

        case .deviceFlowTimedOut:
            return "Complete the browser sign-in more quickly next time."

        case .keychainItemMissing, .keychainMalformed:
            return "Sign in again to refresh your credentials."

        case .tokenExpired:
            return "Sign in again to restore your session."

        case .notSignedIn:
            return "Sign in to get started."

        case .refreshTokenRejected, .refreshClientInvalid:
            return "Sign in again to restore your session."

        case .roleNotAssigned:
            return "Contact your AWS administrator to restore role access."

        case .accountNotFound:
            return "Check your profile's sso_account_id setting."

        default:
            return nil
        }
    }
}
