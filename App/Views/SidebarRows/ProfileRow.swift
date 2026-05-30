import SwiftUI
import AWSConfigINI
import IAMIdentityCenter

/// A profile row in the flat Profiles list: profile name (line 1), `via` badge
/// (line 2), and a trailing status icon. Account and role are *not* shown in the
/// sidebar — they live in the detail pane (plan 2026-05-24, decision #5).
struct ProfileRow: View {
    let item: SidebarProfileItem
    let profileStatus: ProfileAuthStatus?
    var isMinting: Bool = false
    var isRoleRejected: Bool = false

    private var node: ProfileNode { item.node }

    /// Resolves the `(sessionName, accountId, roleName)` tuple for an SSO-backed profile.
    /// Non-SSO profiles return nil and fall back to the inert stub icon.
    private var ssoCoordinates: (session: String, account: String, role: String)? {
        guard let session = node.profile.ssoSession,
              let account = node.profile.ssoAccountId,
              let role = node.profile.ssoRoleName else {
            return nil
        }
        return (session, account, role)
    }

    private var viaColor: Color? {
        item.via.isSSO ? Theme.sessionBadgeColor(for: item.via.label) : nil
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(node.id)
                    .lineLimit(1)
                ViaBadge(label: item.via.label, color: viaColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            icon
                .frame(width: 18)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder private var icon: some View {
        if let status = profileStatus {
            ProfileStatusIcon(
                profileStatus: status,
                isMinting: isMinting,
                isRoleRejected: isRoleRejected
            )
        } else {
            Image(systemName: "person.icloud")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var accessibilityLabel: String {
        let region = node.profile.region ?? "unset"
        let via = item.via.isSSO ? "via \(item.via.label)" : item.via.label
        if let status = profileStatus {
            return "Profile \(node.id), \(status.accessibilityPhrase), \(via), region \(region)"
        }
        if ssoCoordinates != nil {
            return "Profile \(node.id), checking status, \(via), region \(region)"
        }
        return "Profile \(node.id), \(via), region \(region)"
    }
}

// MARK: - Previews

#Preview("ProfileRow – light") {
    ProfileRowGallery()
}

#Preview("ProfileRow – dark") {
    ProfileRowGallery()
        .preferredColorScheme(.dark)
}

/// One row per kind × key status, so the badge hues and status glyphs can be scanned
/// together — and compared across light/dark via the two previews above.
///
/// Deliberately avoids `List` so this preview stays focused on row rendering instead of
/// macOS list hosting. The real list chrome is validated by `ProfileListView` previews;
/// here we just need the row to render. Statuses are seeded in `init` so the first render
/// is final.
private struct ProfileRowGallery: View {
    private func ssoItem(_ name: String, session: String) -> SidebarProfileItem {
        SidebarProfileItem(
            node: ProfileNode(
                id: name,
                profile: .init(region: "us-east-1", ssoSession: session, ssoAccountId: "123456789012", ssoRoleName: "AdministratorAccess"),
                origin: .configOnly
            ),
            via: .session(session)
        )
    }

    private var items: [SidebarProfileItem] {
        [
            ssoItem("acme-prod-admin", session: "acme"),    // ready (green)
            ssoItem("blueriver-dev", session: "blueriver"), // notSignedIn
            SidebarProfileItem(node: ProfileNode(id: "ci-deploy", profile: .init(region: "us-east-1"), origin: .credentialsOnly), via: .longTerm),
            SidebarProfileItem(node: ProfileNode(id: "assume-billing", profile: .init(sourceProfile: "default", roleArn: "arn:aws:iam::412903117204:role/Billing"), origin: .configOnly), via: .other),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                ProfileRow(
                    item: item,
                    profileStatus: status(for: item)
                )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
        }
        .frame(width: 260)
    }

    private func status(for item: SidebarProfileItem) -> ProfileAuthStatus? {
        switch item.node.profile.ssoSession {
        case "acme":
            return .ready(expiresAt: Date().addingTimeInterval(3000))
        case "blueriver":
            return .notSignedIn(sessionName: "blueriver")
        default:
            return nil
        }
    }
}
