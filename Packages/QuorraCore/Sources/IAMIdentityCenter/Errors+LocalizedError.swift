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

        default:
            return nil
        }
    }
}
