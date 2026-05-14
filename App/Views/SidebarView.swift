import SwiftUI
import IAMIdentityCenter

struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    @Environment(ProfilesModel.self) private var profilesModel

    var body: some View {
        switch profilesModel.loadState {
        case .idle, .loading:
            List(selection: $selection) {}
                .listStyle(.sidebar)
                .overlay(ProgressView().controlSize(.small))
        case .failed:
            List(selection: $selection) {}
                .listStyle(.sidebar)
                .overlay(
                    Label("Failed to load profiles", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                )
        case .loaded:
            List(selection: $selection) {
                ssoSessionsSection
                longTermKeysSection
                otherSection
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder private var ssoSessionsSection: some View {
        if !profilesModel.groups.ssoSessions.isEmpty {
            Section("SSO Sessions") {
                ForEach(profilesModel.groups.ssoSessions) { session in
                    if session.profiles.isEmpty {
                        SessionRow(session: session)
                            .tag(SidebarSelection.session(name: session.id))
                    } else {
                        DisclosureGroup {
                            ForEach(session.profiles) { profile in
                                ProfileRow(profile: profile)
                                    .tag(SidebarSelection.profile(name: profile.id))
                            }
                        } label: {
                            SessionRow(session: session)
                        }
                        .tag(SidebarSelection.session(name: session.id))
                    }
                }
            }
        }
    }

    @ViewBuilder private var longTermKeysSection: some View {
        if !profilesModel.groups.longTermKeys.isEmpty {
            Section("Long-term keys") {
                ForEach(profilesModel.groups.longTermKeys) { profile in
                    ProfileRow(profile: profile)
                        .tag(SidebarSelection.profile(name: profile.id))
                }
            }
        }
    }

    @ViewBuilder private var otherSection: some View {
        if !profilesModel.groups.other.isEmpty {
            Section("Other") {
                ForEach(profilesModel.groups.other) { profile in
                    ProfileRow(profile: profile)
                        .tag(SidebarSelection.profile(name: profile.id))
                }
            }
        }
    }
}

#Preview("Sidebar – populated") {
    SidebarPopulatedHarness()
}

#Preview("Sidebar – empty") {
    SidebarView(selection: .constant(nil))
        .environment(ProfilesModel())
        .environment(CredentialsModel(service: PreviewIdentityCenterService()))
}

private struct SidebarPopulatedHarness: View {
    @State private var selection: SidebarSelection? = nil
    @State private var profilesModel = ProfilesModel()
    @State private var credentialsModel = CredentialsModel(service: PreviewIdentityCenterService())

    var body: some View {
        SidebarView(selection: $selection)
            .environment(profilesModel)
            .environment(credentialsModel)
            .task {
                let tmp = FileManager.default.temporaryDirectory
                    .appending(path: UUID().uuidString, directoryHint: .isDirectory)
                try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                try? sampleConfig.write(
                    to: tmp.appending(path: "config", directoryHint: .notDirectory),
                    atomically: true,
                    encoding: .utf8
                )
                try? sampleCredentials.write(
                    to: tmp.appending(path: "credentials", directoryHint: .notDirectory),
                    atomically: true,
                    encoding: .utf8
                )
                await profilesModel.load(folder: tmp)
            }
    }

    private var sampleConfig: String {
        """
        [sso-session acme]
        sso_start_url = https://acme.awsapps.com/start
        sso_region = us-east-1
        sso_registration_scopes = sso:account:access

        [sso-session blueriver]
        sso_start_url = https://blueriver.awsapps.com/start
        sso_region = eu-west-1

        [default]
        sso_session = acme
        sso_account_id = 412903117204
        sso_role_name = AdministratorAccess
        region = us-east-1
        output = json

        [profile acme-prod-admin]
        sso_session = acme
        sso_account_id = 412903117204
        sso_role_name = AdministratorAccess
        region = us-east-1

        [profile acme-prod-readonly]
        sso_session = acme
        sso_account_id = 412903117204
        sso_role_name = ReadOnlyAccess
        region = us-east-1

        [profile blueriver-dev]
        sso_session = blueriver
        sso_account_id = 928104400211
        sso_role_name = DeveloperAccess
        region = eu-west-1

        [profile assume-billing]
        role_arn = arn:aws:iam::412903117204:role/Billing
        source_profile = default
        """
    }

    private var sampleCredentials: String {
        """
        [ci-deploy]
        aws_access_key_id = test-default-access-key
        aws_secret_access_key = test-default-secret-key

        [homelab-backup]
        aws_access_key_id = AKIAJK4OOIK4OOIK4OOI
        aws_secret_access_key = SECRET-DO-NOT-USE-THIS-EXAMPLE-KEY
        """
    }
}

