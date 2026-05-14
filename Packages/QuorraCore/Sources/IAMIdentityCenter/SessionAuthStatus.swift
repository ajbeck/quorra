import Foundation

/// Observed authentication status of a single SSO session.
///
/// Produced by `IdentityCenterService.status(forSession:)` and cached in `CredentialsModel.status`.
/// Views read the cache; the sidebar icon, panel mode, and VoiceOver label all derive from this one value.
///
/// **D1 / D17:** Four-case enum with a `canRefresh` boolean on `signedIn` and `expired` so the UI can
/// disambiguate "expired but will auto-heal" (A2 silent refresh) from "expired, please sign in."
/// `case refreshing` was removed in A2 — "refreshing" is a transient activity overlay, not a session-auth
/// state. The actor's source-of-truth status during refresh is `signedIn(expiresAt:, canRefresh:)`.
/// The overlay lives in `CredentialsModel.refreshingNow: Set<String>`.
public enum SessionAuthStatus: Sendable, Hashable {
    /// No token in the Keychain (never signed in, or after sign-out).
    case signedOut

    /// A valid access token exists; `expiresAt` is the token's wall-clock deadline.
    /// `canRefresh` is `true` when a refresh token was issued with the access token.
    case signedIn(expiresAt: Date, canRefresh: Bool)

    /// Access token's `expiresAt` has passed. `canRefresh` is `true` when a refresh token
    /// is present (A2 will silently renew). `false` means the user must sign in again.
    case expired(expiredAt: Date, canRefresh: Bool)

    /// A device-authorization sign-in flow is in progress for this session.
    case signingIn
    // case refreshing — removed in A2 (D17); lives in CredentialsModel.refreshingNow
}

// MARK: - Sidebar icon properties (D4)

extension SessionAuthStatus {
    /// SF Symbol name for the sidebar status icon.
    ///
    /// Shape (outline vs. filled) is the load-bearing signal per HIG Inclusive color:
    /// outline = action needed or absent; filled = settled / has token.
    /// The refreshing overlay (A2) is applied by `SessionStatusIcon` via `isRefreshing: Bool`.
    public var symbolName: String {
        switch self {
        case .signedOut:
            return "key.icloud"
        case .signedIn:
            return "key.icloud.fill"
        case .expired(_, canRefresh: true):
            // Renders identical to signedIn — A2 silent refresh will heal before next render
            return "key.icloud.fill"
        case .expired(_, canRefresh: false):
            return "key.icloud"
        case .signingIn:
            return "key.icloud.fill"
        }
    }

    /// Whether to apply a symbol effect to this status icon. Nil means no effect.
    ///
    /// Note: `.pulse` for the refreshing state is now applied via `SessionStatusIcon`'s
    /// `isRefreshing: Bool` overlay parameter (D17), not via this enum.
    public enum StatusEffect: Sendable, Hashable {
        /// `.variableColor` repeating — used for `signingIn`.
        case variableColor
        /// `.pulse` repeating — used when `isRefreshing` overlay is active in `SessionStatusIcon`.
        case pulse
    }

    /// Effect to apply to the icon (nil = none). Only `signingIn` applies an effect from
    /// the status itself; the refreshing pulse is driven by the `isRefreshing` overlay.
    public var statusEffect: StatusEffect? {
        switch self {
        case .signingIn:
            return .variableColor
        default:
            return nil
        }
    }

    /// VoiceOver-friendly phrase for this status.
    ///
    /// Used by `SessionRow` to extend the accessibility label so screen-reader users
    /// never depend on color or animation alone.
    public var accessibilityPhrase: String {
        switch self {
        case .signedOut:
            return "signed out"
        case .signedIn(let expiresAt, _):
            let remaining = expiresAt.timeIntervalSinceNow
            if remaining > 3600 {
                let hours = Int(remaining / 3600)
                return "signed in, expires in \(hours) hour\(hours == 1 ? "" : "s")"
            } else if remaining > 0 {
                let minutes = max(1, Int(remaining / 60))
                return "signed in, expires in \(minutes) minute\(minutes == 1 ? "" : "s")"
            } else {
                return "signed in"
            }
        case .expired(_, canRefresh: true):
            return "signed in, refreshing soon"
        case .expired(_, canRefresh: false):
            return "token expired, sign in required"
        case .signingIn:
            return "signing in"
        }
    }
}

// MARK: - Foreground color role (D4)

extension SessionAuthStatus {
    /// Semantic color role for `foregroundStyle`. The view layer maps this to a SwiftUI `Color`.
    public enum ForegroundRole: Sendable, Hashable {
        case secondary   // signedOut
        case green       // signedIn / expired(canRefresh: true)
        case red         // expired(canRefresh: false)
        case tint        // signingIn
    }

    public var foregroundRole: ForegroundRole {
        switch self {
        case .signedOut:
            return .secondary
        case .signedIn:
            return .green
        case .expired(_, canRefresh: true):
            // Deliberately identical to signedIn per D4 — stable until A2 fixes the state
            return .green
        case .expired(_, canRefresh: false):
            return .red
        case .signingIn:
            return .tint
        }
    }
}
