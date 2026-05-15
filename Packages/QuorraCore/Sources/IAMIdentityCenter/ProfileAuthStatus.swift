import Foundation

/// Observed authentication status of a single profile — i.e. whether Quorra can serve fresh
/// role credentials for a `(sessionName, accountId, roleName)` tuple right now.
///
/// Produced by `IdentityCenterService.status(forProfile:accountId:roleName:)` and cached in
/// `CredentialsModel` (chunk 6). The profile-row icon, the credentials reveal section, and the
/// VoiceOver label all derive from this one value.
///
/// **D29:** Three-case steady-state enum. Transient activity ("minting", "mint failed",
/// "role rejected") is NOT modeled here — per the A1 D17 lesson, transient overlays live in
/// `CredentialsModel` `Set<String>` properties (chunk 6) and are combined with this value at
/// render time by `ProfileStatusIcon`. Mirrors `SessionAuthStatus`'s shape exactly: an enum
/// plus pure derivation helpers, no `import SwiftUI`.
///
/// Research §09 "active" semantics: a profile is "ready" when the underlying SSO bearer is (or
/// can become) valid — even if the cached role-cred row is stale or absent, because the next
/// `liveCredentials` call mints transparently. `expiresAt` carries the cached row's deadline
/// when one exists, or `nil` when there is no cached row yet (still "ready").
public enum ProfileAuthStatus: Sendable, Hashable {
    /// The SSO bearer is valid or silently refreshable; Quorra can serve fresh role
    /// credentials without user interaction. `expiresAt` is the cached role-cred row's
    /// wall-clock deadline, or `nil` when no row is cached yet (mint-on-demand).
    case ready(expiresAt: Date?)

    /// The underlying SSO session has no token (never signed in, or signed out).
    /// The user must run the device-authorization sign-in flow.
    case notSignedIn(sessionName: String)

    /// The SSO token expired with no refresh path (`canRefresh == false`). The user must
    /// sign in again — silent refresh cannot recover this profile.
    case signInExpired(sessionName: String)
}

// MARK: - Profile-row icon properties (D31)

extension ProfileAuthStatus {
    /// SF Symbol name for the profile-row status icon.
    ///
    /// `person.icloud` (vs. the session row's `key.icloud`) — the profile represents
    /// identity-as-a-role; the session represents the SSO bearer. Shape is the load-bearing
    /// signal per HIG Inclusive color: outline = action needed; filled = ready.
    ///
    /// Overlay-driven rows in the D31 matrix (`ready + mintingNow` → `.pulse`,
    /// `ready + roleRejected` → red outline) are applied by `ProfileStatusIcon` (chunk 6)
    /// by combining this base mapping with `CredentialsModel`'s overlay `Set`s — exactly
    /// how A1's `SessionStatusIcon` layers the `isRefreshing` overlay on `SessionAuthStatus`.
    public var symbolName: String {
        switch self {
        case .ready:
            return "person.icloud.fill"
        case .notSignedIn:
            return "person.icloud"
        case .signInExpired:
            return "person.icloud"
        }
    }

    /// Symbol effect driven by the status itself. Nil for every steady state — the only
    /// profile-row effect (`.pulse` for an in-flight mint) is overlay-driven by
    /// `ProfileStatusIcon` (chunk 6), not by this enum. Mirrors `SessionAuthStatus`'s
    /// split between self-driven effects and the `isRefreshing` overlay.
    public enum StatusEffect: Sendable, Hashable {
        /// `.pulse` repeating — applied by `ProfileStatusIcon` when the `mintingNow` overlay
        /// is active for the tuple (chunk 6). Never produced by `statusEffect` itself.
        case pulse
    }

    /// Effect to apply from the status alone (always nil — see `StatusEffect`).
    public var statusEffect: StatusEffect? {
        nil
    }
}

// MARK: - Foreground color role (D31)

extension ProfileAuthStatus {
    /// Semantic color role for `foregroundStyle`. The view layer maps this to a SwiftUI `Color`.
    public enum ForegroundRole: Sendable, Hashable {
        case green       // ready
        case secondary   // notSignedIn
        case red         // signInExpired (and, via overlay in chunk 6, ready + roleRejected)
    }

    public var foregroundRole: ForegroundRole {
        switch self {
        case .ready:
            return .green
        case .notSignedIn:
            return .secondary
        case .signInExpired:
            return .red
        }
    }
}

// MARK: - Accessibility

extension ProfileAuthStatus {
    /// VoiceOver-friendly phrase for this status, so screen-reader users never depend on
    /// color or shape alone. Used by `ProfileRow` to extend its accessibility label (chunk 6).
    public var accessibilityPhrase: String {
        switch self {
        case .ready(let expiresAt):
            guard let expiresAt else {
                return "active, credentials ready"
            }
            let remaining = expiresAt.timeIntervalSinceNow
            if remaining > 3600 {
                let hours = Int(remaining / 3600)
                return "active, credentials expire in \(hours) hour\(hours == 1 ? "" : "s")"
            } else if remaining > 0 {
                let minutes = max(1, Int(remaining / 60))
                return "active, credentials expire in \(minutes) minute\(minutes == 1 ? "" : "s")"
            } else {
                // Stale cached row but bearer still valid — next read mints transparently
                return "active, credentials ready"
            }
        case .notSignedIn:
            return "signed out, sign in required"
        case .signInExpired:
            return "session expired, sign in required"
        }
    }
}
