import SwiftUI
import AWSConfigINI
import IAMIdentityCenter

struct ProfileRow: View {
    let profile: ProfileNode
    @Environment(CredentialsModel.self) private var credentialsModel

    /// Resolves the `(sessionName, accountId, roleName)` tuple for an SSO-backed profile.
    /// Non-SSO profiles (static creds, role-assumption, credential_process) return nil and
    /// fall back to the inert stub icon — `ProfileAuthStatus` only applies to SSO profiles.
    private var ssoCoordinates: (session: String, account: String, role: String)? {
        guard let session = profile.profile.ssoSession,
              let account = profile.profile.ssoAccountId,
              let role = profile.profile.ssoRoleName else {
            return nil
        }
        return (session, account, role)
    }

    private var statusKey: String? {
        guard let c = ssoCoordinates else { return nil }
        return "\(c.session):\(c.account):\(c.role)"
    }

    private var profileStatus: ProfileAuthStatus? {
        guard let key = statusKey else { return nil }
        return credentialsModel.profileStatus[key]
    }

    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(profile.id)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .task(id: statusKey) {
            // Only SSO-backed profiles have a ProfileAuthStatus to observe. Apple:
            // SwiftUI/View/task(id:…) — cancels on disappear, restarts on key change.
            guard let c = ssoCoordinates else { return }
            await credentialsModel.observeProfileStatus(
                forSession: c.session,
                accountId: c.account,
                roleName: c.role
            )
        }
    }

    @ViewBuilder private var icon: some View {
        if let status = profileStatus, let key = statusKey {
            // ProfileStatusIcon is accessibility-hidden; the row label carries the phrase.
            ProfileStatusIcon(
                profileStatus: status,
                isMinting: credentialsModel.mintingNow.contains(key),
                isRoleRejected: credentialsModel.roleRejected.contains(key)
            )
        } else {
            // Non-SSO profile, or status not yet observed: inert placeholder.
            Image(systemName: "person.icloud")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var accessibilityLabel: String {
        let region = profile.profile.region ?? "unset"
        if let status = profileStatus {
            return "Profile \(profile.id), \(status.accessibilityPhrase), region \(region)"
        }
        if ssoCoordinates != nil {
            return "Profile \(profile.id), checking status, region \(region)"
        }
        return "Profile \(profile.id), region \(region)"
    }
}

// MARK: - Previews

#Preview("ProfileRow – ready") {
    let node = ProfileNode(
        id: "acme-prod-admin",
        profile: .init(
            region: "us-east-1",
            ssoSession: "acme",
            ssoAccountId: "123456789012",
            ssoRoleName: "AdministratorAccess"
        ),
        origin: .configOnly
    )
    let model = CredentialsModel(service: PreviewIdentityCenterService())
    ProfileRow(profile: node)
        .environment(model)
        .task {
            model.seedProfileStatusForTesting(
                .ready(expiresAt: Date().addingTimeInterval(3000)),
                key: "acme:123456789012:AdministratorAccess"
            )
        }
        .padding()
}

#Preview("ProfileRow – ready + minting") {
    let node = ProfileNode(
        id: "acme-prod-admin",
        profile: .init(region: "us-east-1", ssoSession: "acme", ssoAccountId: "123456789012", ssoRoleName: "AdministratorAccess"),
        origin: .configOnly
    )
    let model = CredentialsModel(service: PreviewIdentityCenterService())
    ProfileRow(profile: node)
        .environment(model)
        .task {
            model.seedProfileStatusForTesting(.ready(expiresAt: nil), key: "acme:123456789012:AdministratorAccess")
            model.seedMintingNowForTesting(key: "acme:123456789012:AdministratorAccess")
        }
        .padding()
}

#Preview("ProfileRow – ready + roleRejected") {
    let node = ProfileNode(
        id: "acme-billing",
        profile: .init(region: "us-east-1", ssoSession: "acme", ssoAccountId: "123456789012", ssoRoleName: "Billing"),
        origin: .configOnly
    )
    let model = CredentialsModel(service: PreviewIdentityCenterService())
    ProfileRow(profile: node)
        .environment(model)
        .task {
            model.seedProfileStatusForTesting(.ready(expiresAt: nil), key: "acme:123456789012:Billing")
            model.seedRoleRejectedForTesting(key: "acme:123456789012:Billing")
        }
        .padding()
}

#Preview("ProfileRow – notSignedIn") {
    let node = ProfileNode(
        id: "acme-prod-admin",
        profile: .init(region: "us-east-1", ssoSession: "acme", ssoAccountId: "123456789012", ssoRoleName: "AdministratorAccess"),
        origin: .configOnly
    )
    let model = CredentialsModel(service: PreviewIdentityCenterService())
    ProfileRow(profile: node)
        .environment(model)
        .task {
            model.seedProfileStatusForTesting(.notSignedIn(sessionName: "acme"), key: "acme:123456789012:AdministratorAccess")
        }
        .padding()
}

#Preview("ProfileRow – non-SSO profile (inert icon)") {
    let node = ProfileNode(
        id: "static-creds",
        profile: .init(region: "us-west-2"),
        origin: .credentialsOnly
    )
    let model = CredentialsModel(service: PreviewIdentityCenterService())
    ProfileRow(profile: node)
        .environment(model)
        .padding()
}
