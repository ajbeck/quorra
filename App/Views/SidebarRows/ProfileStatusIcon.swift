import SwiftUI
import IAMIdentityCenter

/// Pure view: renders the `person.icloud` SF Symbol in the shape, color, and effect
/// prescribed by `ProfileAuthStatus` per D31.
///
/// `person.icloud` (vs. the session row's `key.icloud`) disambiguates identity-as-a-role
/// from the SSO bearer. Shape (outline vs. filled) is the load-bearing accessibility signal
/// per HIG Inclusive color. Color is semantic. Motion respects Reduce Motion automatically
/// because `symbolEffect(_:options:isActive:)` is Apple-provided.
///
/// Two overlay parameters layer on top of the steady-state `ProfileAuthStatus`, exactly as
/// A1's `SessionStatusIcon` layers `isRefreshing`:
/// - `isMinting` (caller passes `model.mintingNow.contains(key)`): adds the `.pulse` effect
///   while a mint is in flight. The icon stays green/filled — only motion changes.
/// - `isRoleRejected` (caller passes `model.roleRejected.contains(key)`): a terminal
///   access-denied overlay. Per the D31 matrix, `ready + roleRejected` renders as the
///   outline `person.icloud` in `.red` (the profile can't serve credentials until an
///   admin restores access). Only meaningful when the status is `.ready` — a non-ready
///   status already conveys the blocking condition.
///
/// `mintFailure` deliberately has NO icon effect: research §09 says stale-but-mintable
/// counts as "active", so a transient failure stays green; its advisory surfaces only in
/// the detail view (D31).
///
/// Apple: SwiftUI/View/symbolEffect(_:options:isActive:)
struct ProfileStatusIcon: View {
    let profileStatus: ProfileAuthStatus
    var isMinting: Bool = false
    var isRoleRejected: Bool = false

    var body: some View {
        Image(systemName: symbolName)
            .foregroundStyle(foregroundColor)
            // D31: minting overlay — pulse driven by CredentialsModel.mintingNow.
            .symbolEffect(
                .pulse,
                options: .repeating,
                isActive: isMinting
            )
            .accessibilityHidden(true)  // Parent row carries the accessibility label
    }

    /// `ready + roleRejected` overrides the filled symbol with the outline form (D31 matrix);
    /// otherwise the steady-state mapping from `ProfileAuthStatus` applies.
    private var symbolName: String {
        if isRoleRejected, case .ready = profileStatus {
            return "person.icloud"
        }
        return profileStatus.symbolName
    }

    /// `ready + roleRejected` overrides green with red (D31 matrix); otherwise the
    /// steady-state role from `ProfileAuthStatus`.
    private var foregroundColor: Color {
        if isRoleRejected, case .ready = profileStatus {
            return .red
        }
        switch profileStatus.foregroundRole {
        case .green:
            return .green
        case .secondary:
            return .secondary
        case .red:
            return .red
        }
    }
}

// MARK: - Previews

#Preview("ready") {
    ProfileStatusIcon(profileStatus: .ready(expiresAt: Date().addingTimeInterval(3600)))
        .padding()
}

#Preview("ready + minting") {
    ProfileStatusIcon(
        profileStatus: .ready(expiresAt: Date().addingTimeInterval(3600)),
        isMinting: true
    )
    .padding()
}

#Preview("ready + roleRejected") {
    ProfileStatusIcon(
        profileStatus: .ready(expiresAt: nil),
        isRoleRejected: true
    )
    .padding()
}

#Preview("notSignedIn") {
    ProfileStatusIcon(profileStatus: .notSignedIn(sessionName: "acme"))
        .padding()
}

#Preview("signInExpired") {
    ProfileStatusIcon(profileStatus: .signInExpired(sessionName: "acme"))
        .padding()
}
