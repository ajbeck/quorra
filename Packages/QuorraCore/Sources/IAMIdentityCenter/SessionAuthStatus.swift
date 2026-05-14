import Foundation

/// Observed authentication status of a single SSO session.
///
/// Produced by `IdentityCenterService.status(forSession:)` and cached in `CredentialsModel.status`.
/// Views read the cache; the sidebar icon, panel mode, and VoiceOver label all derive from this one value.
///
/// **D1:** Five-case enum with a `canRefresh` boolean on `signedIn` and `expired` so the UI can
/// disambiguate "expired but will auto-heal" (A2 silent refresh) from "expired, please sign in."
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

    /// A silent refresh is in flight (A2).
    case refreshing
}

// MARK: - Sidebar icon properties (D4)

extension SessionAuthStatus {
    /// SF Symbol name for the sidebar status icon.
    ///
    /// Shape (outline vs. filled) is the load-bearing signal per HIG Inclusive color:
    /// outline = action needed or absent; filled = settled / has token.
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
        case .refreshing:
            return "key.icloud.fill"
        }
    }

    /// Whether to apply a symbol effect to this status icon. Nil means no effect.
    public enum StatusEffect: Sendable, Hashable {
        /// `.variableColor` repeating — used for `signingIn`.
        case variableColor
        /// `.pulse` repeating — used for `refreshing` (A2).
        case pulse
    }

    /// Effect to apply to the icon (nil = none).
    public var statusEffect: StatusEffect? {
        switch self {
        case .signingIn:
            return .variableColor
        case .refreshing:
            return .pulse
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
        case .refreshing:
            return "refreshing"
        }
    }
}

// MARK: - Foreground color role (D4)

extension SessionAuthStatus {
    /// Semantic color role for `foregroundStyle`. The view layer maps this to a SwiftUI `Color`.
    public enum ForegroundRole: Sendable, Hashable {
        case secondary   // signedOut
        case green       // signedIn / expired(canRefresh: true) / refreshing
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
        case .refreshing:
            return .green
        }
    }
}
