import SwiftUI
import IAMIdentityCenter

/// Pure view: renders the `key.icloud` SF Symbol in the shape, color, and effect
/// prescribed by `SessionAuthStatus` per D4.
///
/// Shape (outline vs. filled) is the load-bearing signal for accessibility per HIG
/// Inclusive color. Color is semantic. Motion respects Reduce Motion automatically
/// because `symbolEffect(_:options:isActive:)` is Apple-provided.
///
/// Apple: SwiftUI/View/symbolEffect(_:options:isActive:)
struct SessionStatusIcon: View {
    let authStatus: SessionAuthStatus

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
            .symbolEffect(
                .pulse,
                options: .repeating,
                isActive: authStatus.statusEffect == .pulse
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

#Preview("refreshing") {
    SessionStatusIcon(authStatus: .refreshing)
        .padding()
}
