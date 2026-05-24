import SwiftUI
import IAMIdentityCenter

struct MainView: View {
    let folderURL: URL
    let loadsProfilesOnAppear: Bool
    @Environment(AppModel.self) private var appModel
    @Environment(ProfilesModel.self) private var profilesModel
    @State private var selection: SidebarSelection? = nil

    init(folderURL: URL, loadsProfilesOnAppear: Bool = true) {
        self.folderURL = folderURL
        self.loadsProfilesOnAppear = loadsProfilesOnAppear
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            DetailView(selection: $selection)
        }
        .toolbar { toolbarContent }
        .task(id: folderURL) {
            guard loadsProfilesOnAppear else { return }
            await profilesModel.load(folder: folderURL)
        }
        .onAppear {
            selectDefaultProfileIfNeeded()
        }
        .onChange(of: profilesModel.loadState) { _, newState in
            guard newState == .loaded else { return }
            selectDefaultProfileIfNeeded()
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await profilesModel.reload() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: [.command])
        }
    }

    private func selectDefaultProfileIfNeeded() {
        guard selection == nil, profilesModel.loadState == .loaded else { return }
        let groups = profilesModel.groups
        if let firstSession = groups.ssoSessions.first, let firstProfile = firstSession.profiles.first {
            selection = .profile(name: firstProfile.id)
        } else if let firstLTK = groups.longTermKeys.first {
            selection = .profile(name: firstLTK.id)
        } else if let firstOther = groups.other.first {
            selection = .profile(name: firstOther.id)
        }
    }
}

#Preview("Main – empty folder") {
    let folderURL = URL(filePath: "/nonexistent/aws-folder")
    MainView(folderURL: folderURL, loadsProfilesOnAppear: false)
        .environment(AppModel(initialPhase: .ready(folderURL)))
        .environment(ProfilesModel.previewLoaded(config: "", folder: folderURL))
        .environment(EditorState())
        .environment(CredentialsModel(service: PreviewIdentityCenterService()))
}

#Preview("Main – with sample data") {
    MainViewSampleDataHarness()
}

private struct MainViewSampleDataHarness: View {
    private let folderURL = URL(filePath: "/preview/.aws", directoryHint: .isDirectory)
    @State private var appModel: AppModel
    @State private var profilesModel: ProfilesModel
    @State private var editorState: EditorState
    @State private var credentialsModel: CredentialsModel

    init() {
        let folderURL = URL(filePath: "/preview/.aws", directoryHint: .isDirectory)
        let profiles = ProfilesModel.previewLoaded(
            config: Self.sampleConfig,
            credentials: Self.sampleCredentials,
            folder: folderURL
        )
        let creds = CredentialsModel(service: PreviewIdentityCenterService())
        creds.seedProfileStatusForTesting(.ready(expiresAt: Date().addingTimeInterval(6 * 3600)), key: "acme:412903117204:AdministratorAccess")
        creds.seedProfileStatusForTesting(.ready(expiresAt: Date().addingTimeInterval(6 * 3600)), key: "acme:412903117204:ReadOnlyAccess")
        creds.seedProfileStatusForTesting(.notSignedIn(sessionName: "blueriver"), key: "blueriver:928104400211:DeveloperAccess")
        creds.seedStatusForTesting(.signedIn(expiresAt: Date().addingTimeInterval(6 * 3600), canRefresh: true), sessionName: "acme")
        creds.seedStatusForTesting(.expired(expiredAt: Date().addingTimeInterval(-2 * 86400), canRefresh: false), sessionName: "blueriver")

        _appModel = State(initialValue: AppModel(initialPhase: .ready(folderURL)))
        _profilesModel = State(initialValue: profiles)
        _editorState = State(initialValue: EditorState())
        _credentialsModel = State(initialValue: creds)
    }

    var body: some View {
        MainView(folderURL: folderURL, loadsProfilesOnAppear: false)
            .environment(appModel)
            .environment(profilesModel)
            .environment(editorState)
            .environment(credentialsModel)
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
    aws_access_key_id = test-default-access-key
    aws_secret_access_key = test-default-secret-key

    [homelab-backup]
    aws_access_key_id = AKIAJK4OOIK4OOIK4OOI
    aws_secret_access_key = SECRET-DO-NOT-USE-THIS-EXAMPLE-KEY
    """
}
