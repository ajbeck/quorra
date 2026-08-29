import SwiftUI
import IAMIdentityCenter
import QuorraAppLogic

/// Pure view: renders the `key.icloud` SF Symbol in the shape, color, and effect
/// prescribed by `SessionAuthStatus` per D4.
///
/// Shape (outline vs. filled) is the load-bearing signal for accessibility per HIG
/// Inclusive color. Color is semantic. Motion respects Reduce Motion automatically
/// because `symbolEffect(_:options:isActive:)` is Apple-provided.
///
/// **A2 (D17):** `isRefreshing: Bool` overlay parameter drives the `.pulse` effect.
/// The pulse is independent of the auth status — the icon stays green/filled while
/// refresh is in flight; only the motion changes. Callers pass
/// `credentialsModel.refreshingNow.contains(session.id)`.
///
/// Apple: SwiftUI/View/symbolEffect(_:options:isActive:)
struct SessionStatusIcon: View {
    let authStatus: SessionAuthStatus
    var isRefreshing: Bool = false

    var body: some View {
        Image(systemName: authStatus.symbolName)
            .foregroundStyle(foregroundColor)
            // Apple: SwiftUI/View/symbolEffect(_:options:isActive:) — `isActive` false = no motion,
            // and the effect respects Reduce Motion automatically when active.
            .symbolEffect(
                .variableColor.iterative.reversing,
                options: .repeating,
                isActive: authStatus.statusEffect == .variableColor
            )
            // D17: refreshing overlay — pulse effect driven by CredentialsModel.refreshingNow
            .symbolEffect(
                .pulse,
                options: .repeating,
                isActive: isRefreshing
            )
            .accessibilityHidden(true)  // Parent row carries the accessibility label
    }

    private var foregroundColor: Color {
        switch authStatus.foregroundRole {
        case .secondary:
            return .secondary
        case .green:
            return .green
        case .red:
            return .red
        case .tint:
            return .accentColor
        }
    }
}

// MARK: - Previews

#if DEBUG

#Preview("signedOut") {
    SessionStatusIcon(authStatus: .signedOut)
        .padding()
}

#Preview("signedIn") {
    SessionStatusIcon(authStatus: .signedIn(expiresAt: Date().addingTimeInterval(3600), canRefresh: false))
        .padding()
}

#Preview("expired – needs sign in") {
    SessionStatusIcon(authStatus: .expired(expiredAt: Date().addingTimeInterval(-60), canRefresh: false))
        .padding()
}

#Preview("expired – canRefresh") {
    SessionStatusIcon(authStatus: .expired(expiredAt: Date().addingTimeInterval(-60), canRefresh: true))
        .padding()
}

#Preview("signingIn") {
    SessionStatusIcon(authStatus: .signingIn)
        .padding()
}

#Preview("refreshing overlay") {
    SessionStatusIcon(
        authStatus: .signedIn(expiresAt: Date().addingTimeInterval(3600), canRefresh: true),
        isRefreshing: true
    )
    .padding()
}

#endif
