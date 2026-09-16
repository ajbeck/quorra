import Foundation
import IAMIdentityCenter

/// Whether a profile can serve credentials right now, derived from the cached auth state.
///
/// One answer shared by the endpoint detail, the menu bar, and the runtime coordinator, so a
/// session that needs the user to sign in is called out the same way everywhere.
public enum ProfileCredentialReadiness: Equatable, Sendable {
    /// No cached profile status yet.
    case checking
    /// A device-authorization sign-in is in flight for the session.
    case signingIn
    /// The session is signed out, expired without a refresh path, or its silent refresh failed.
    case needsSignIn(sessionName: String)
    /// Credentials can be served or minted without user interaction.
    case ready
    /// The profile has no session, or Identity Center rejected the role.
    case unavailable

    /// Resolves the readiness from the pieces `CredentialsModel` caches.
    ///
    /// The session status wins over the profile status because it is the fresher signal: an
    /// expired session with a refresh token still counts as ready until a refresh has failed,
    /// so silent refresh keeps working; once one fails, the user has to sign in.
    public static func resolve(
        sessionName: String?,
        sessionStatus: SessionAuthStatus?,
        profileStatus: ProfileAuthStatus?,
        isSignInInFlight: Bool,
        isRoleRejected: Bool,
        hasRefreshFailure: Bool
    ) -> ProfileCredentialReadiness {
        guard let sessionName else { return .unavailable }
        if isSignInInFlight { return .signingIn }
        if case .signingIn = sessionStatus { return .signingIn }
        if isRoleRejected { return .unavailable }

        switch sessionStatus {
        case .signedOut, .expired(_, canRefresh: false):
            return .needsSignIn(sessionName: sessionName)
        case .expired(_, canRefresh: true) where hasRefreshFailure:
            return .needsSignIn(sessionName: sessionName)
        case .signedIn, .expired, .signingIn, .none:
            break
        }

        switch profileStatus {
        case .none:
            return .checking
        case .notSignedIn(let name), .signInExpired(let name):
            return .needsSignIn(sessionName: name)
        case .ready:
            return .ready
        }
    }
}

public extension CredentialsModel {
    func readiness(forSession sessionName: String, accountId: String, roleName: String) -> ProfileCredentialReadiness {
        let key = "\(sessionName):\(accountId):\(roleName)"
        return ProfileCredentialReadiness.resolve(
            sessionName: sessionName,
            sessionStatus: status[sessionName],
            profileStatus: profileStatus[key],
            isSignInInFlight: inFlight[sessionName] != nil,
            isRoleRejected: roleRejected.contains(key),
            hasRefreshFailure: refreshFailure.contains(sessionName)
        )
    }

    func readiness(for profile: ProfileDefinition) -> ProfileCredentialReadiness {
        guard let coordinates = profile.credentialCoordinates else { return .unavailable }
        return readiness(forSession: coordinates.session, accountId: coordinates.account, roleName: coordinates.role)
    }
}
