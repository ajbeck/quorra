import SwiftUI
import AWSConfigINI
import IAMIdentityCenter

struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    @Environment(ProfilesModel.self) private var profilesModel
    @Environment(CredentialsModel.self) private var credentialsModel

    @State private var tab: SidebarTab = .profiles
    @State private var filter: String = ""

    enum SidebarTab: Hashable { case profiles, sessions }

    var body: some View {
        switch profilesModel.loadState {
        case .idle, .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView(
                "Failed to Load Profiles",
                systemImage: "exclamationmark.triangle",
                description: Text("Quorra couldn't read your AWS configuration.")
            )
        case .loaded:
            loadedView
        }
    }

    // MARK: - Loaded

    private var loadedView: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                Text("Profiles \(profileItems.count)").tag(SidebarTab.profiles)
                Text("SSO Sessions \(sessions.count)").tag(SidebarTab.sessions)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)

            sidebarList
        }
        .searchable(text: $filter, placement: .sidebar, prompt: searchPrompt)
        .onChange(of: selection) { _, newValue in
            syncTab(to: newValue)
        }
    }

    @ViewBuilder private var sidebarList: some View {
        switch tab {
        case .profiles:
            profilesList
        case .sessions:
            sessionsList
        }
    }

    private var profilesList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                profileRows
            }
            .padding(.vertical, 4)
        }
        .overlay { emptyOverlay }
    }

    private var sessionsList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                sessionRows
            }
            .padding(.vertical, 4)
        }
        .overlay { emptyOverlay }
    }

    @ViewBuilder private var profileRows: some View {
        ForEach(filteredProfiles) { item in
            let key = statusKey(for: item)
            sidebarButton(for: .profile(name: item.id)) {
                ProfileRow(
                    item: item,
                    profileStatus: key.flatMap { credentialsModel.profileStatus[$0] },
                    isMinting: key.map { credentialsModel.mintingNow.contains($0) } ?? false,
                    isRoleRejected: key.map { credentialsModel.roleRejected.contains($0) } ?? false
                )
            }
            .task(id: key) {
                guard let coordinates = ssoCoordinates(for: item) else { return }
                await credentialsModel.observeProfileStatus(
                    forSession: coordinates.session,
                    accountId: coordinates.account,
                    roleName: coordinates.role
                )
            }
        }
    }

    @ViewBuilder private var sessionRows: some View {
        ForEach(filteredSessions) { node in
            sidebarButton(for: .session(name: node.id)) {
                SessionRow(
                    session: node,
                    authStatus: credentialsModel.status[node.id] ?? .signedOut,
                    isRefreshing: credentialsModel.refreshingNow.contains(node.id)
                )
            }
            .task(id: node.id) {
                await credentialsModel.observeStatus(forSession: node.id)
            }
        }
    }

    private func sidebarButton<Content: View>(
        for value: SidebarSelection,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button {
            selection = value
        } label: {
            content()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if selection == value {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
            }
        }
        .padding(.horizontal, 6)
        .accessibilityAddTraits(selection == value ? .isSelected : [])
    }

    @ViewBuilder private var emptyOverlay: some View {
        let isEmpty = tab == .profiles ? filteredProfiles.isEmpty : filteredSessions.isEmpty
        if isEmpty {
            if !filter.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else if tab == .profiles {
                ContentUnavailableView("No Profiles", systemImage: "person.crop.circle.badge.questionmark")
            } else {
                ContentUnavailableView("No SSO Sessions", systemImage: "key.icloud")
            }
        }
    }

    // MARK: - Data

    private var profileItems: [SidebarProfileItem] { profilesModel.groups.flatProfiles }
    private var sessions: [SSOSessionNode] { profilesModel.groups.ssoSessions }

    private var filteredProfiles: [SidebarProfileItem] {
        guard !filter.isEmpty else { return profileItems }
        return profileItems.filter {
            $0.id.localizedCaseInsensitiveContains(filter)
                || $0.via.label.localizedCaseInsensitiveContains(filter)
        }
    }

    private var filteredSessions: [SSOSessionNode] {
        guard !filter.isEmpty else { return sessions }
        return sessions.filter { $0.id.localizedCaseInsensitiveContains(filter) }
    }

    private var searchPrompt: String {
        tab == .profiles ? "Filter profiles" : "Filter sessions"
    }

    private func ssoCoordinates(for item: SidebarProfileItem) -> (session: String, account: String, role: String)? {
        guard let session = item.node.profile.ssoSession,
              let account = item.node.profile.ssoAccountId,
              let role = item.node.profile.ssoRoleName else {
            return nil
        }
        return (session, account, role)
    }

    private func statusKey(for item: SidebarProfileItem) -> String? {
        guard let coordinates = ssoCoordinates(for: item) else { return nil }
        return "\(coordinates.session):\(coordinates.account):\(coordinates.role)"
    }

    /// When the selection changes *kind* (e.g. a detail-pane cross-link sets a session
    /// while the Profiles tab is showing), follow it so the selected row is visible.
    /// User-initiated tab switches never change the selection, so they don't loop here.
    private func syncTab(to selection: SidebarSelection?) {
        switch selection {
        case .profile: tab = .profiles
        case .session: tab = .sessions
        case .none: break
        }
    }
}

// MARK: - Previews

// Previews host the sidebar inside a `NavigationSplitView` (its real context in `MainView`)
// and seed a fully-loaded, stable model up front. Production and previews share the same
// custom row container; no file I/O or async model loading is needed for the preview frame.

#Preview("Sidebar – populated") {
    SidebarPreviewHarness()
}

#Preview("Sidebar – loading") {
    NavigationSplitView {
        SidebarView(selection: .constant(nil))
    } detail: {
        Text("Select an item").foregroundStyle(.secondary)
    }
    .environment(ProfilesModel())   // .idle → ProgressView; stable, never flips
    .environment(CredentialsModel(service: PreviewIdentityCenterService()))
}

private struct SidebarPreviewHarness: View {
    @State private var selection: SidebarSelection?
    @State private var profilesModel: ProfilesModel
    @State private var credentialsModel: CredentialsModel

    init() {
        let profiles = ProfilesModel.previewLoaded(config: Self.sampleConfig, credentials: Self.sampleCredentials)
        let creds = CredentialsModel(service: PreviewIdentityCenterService())
        // Seed every observable status so the first frame is final.
        creds.seedProfileStatusForTesting(.ready(expiresAt: Date().addingTimeInterval(6 * 3600)), key: "acme:412903117204:AdministratorAccess")
        creds.seedProfileStatusForTesting(.ready(expiresAt: Date().addingTimeInterval(6 * 3600)), key: "acme:412903117204:ReadOnlyAccess")
        creds.seedProfileStatusForTesting(.notSignedIn(sessionName: "blueriver"), key: "blueriver:928104400211:DeveloperAccess")
        creds.seedStatusForTesting(.signedIn(expiresAt: Date().addingTimeInterval(6 * 3600), canRefresh: true), sessionName: "acme")
        creds.seedStatusForTesting(.expired(expiredAt: Date().addingTimeInterval(-2 * 86400), canRefresh: false), sessionName: "blueriver")
        _profilesModel = State(initialValue: profiles)
        _credentialsModel = State(initialValue: creds)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            Text(detailLabel).foregroundStyle(.secondary)
        }
        .environment(profilesModel)
        .environment(credentialsModel)
    }

    private var detailLabel: String {
        switch selection {
        case .profile(let name): "Profile · \(name)"
        case .session(let name): "Session · \(name)"
        case .none: "Select an item"
        }
    }

    private static let sampleConfig = """
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

    private static let sampleCredentials = """
    [ci-deploy]
    aws_access_key_id = AKIAIOSFODNN7EXAMPLE
    aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

    [homelab-backup]
    aws_access_key_id = AKIAJK4OOIK4OOIK4OOI
    aws_secret_access_key = SECRET-DO-NOT-USE-THIS-EXAMPLE-KEY
    """
}
