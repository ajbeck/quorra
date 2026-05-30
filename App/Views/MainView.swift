import SwiftUI
import IAMIdentityCenter

struct MainView: View {
    let folderURL: URL
    let loadsProfilesOnAppear: Bool
    @Environment(AppModel.self) private var appModel
    @Environment(ProfilesModel.self) private var profilesModel
    @State private var sessionFilter: SessionFilter = .all
    @State private var selection: DetailSelection? = nil

    init(folderURL: URL, loadsProfilesOnAppear: Bool = true) {
        self.folderURL = folderURL
        self.loadsProfilesOnAppear = loadsProfilesOnAppear
    }

    var body: some View {
        NavigationSplitView {
            SessionRailView(filter: $sessionFilter)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
        } content: {
            ProfileListView(sessionFilter: $sessionFilter, selection: $selection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 380)
        } detail: {
            DetailView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 520, ideal: 760)
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
        selection = profilesModel.groups.flatProfiles.first.map { .profile(name: $0.id) }
    }
}

#Preview("Main – empty folder") {
    let folderURL = URL(filePath: "/nonexistent/aws-folder")
    MainView(folderURL: folderURL, loadsProfilesOnAppear: false)
        .environment(AppModel(initialPhase: .ready(folderURL)))
        .environment(ProfilesModel.previewLoaded(config: "", folder: folderURL))
        .environment(EditorState())
        .environment(CredentialsModel(service: PreviewIdentityCenterService()))
        .environment(IMDSModel())
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
    @State private var imdsModel: IMDSModel

    init() {
        let folderURL = URL(filePath: "/preview/.aws", directoryHint: .isDirectory)
        let profiles = ProfilesModel.previewLoaded(
            config: PreviewAWSFixtures.mockupConfig,
            credentials: PreviewAWSFixtures.mockupCredentials,
            folder: folderURL
        )
        let creds = CredentialsModel(service: PreviewIdentityCenterService())
        creds.seedProfileStatusForTesting(.ready(expiresAt: Date().addingTimeInterval(6 * 3600 + 12 * 60)), key: "astrocompute:699475923216:OrganizationAdmin")
        creds.seedProfileStatusForTesting(.ready(expiresAt: Date().addingTimeInterval(6 * 3600 + 12 * 60)), key: "astrocompute:699475923216:ManagementAdmin")
        creds.seedProfileStatusForTesting(.ready(expiresAt: Date().addingTimeInterval(6 * 3600 + 12 * 60)), key: "astrocompute:699475923216:ManagementOrganizationAdmin")
        creds.seedProfileStatusForTesting(.ready(expiresAt: Date().addingTimeInterval(6 * 3600 + 12 * 60)), key: "astrocompute:699475923216:PersonalOrganizationAdmin")
        creds.seedProfileStatusForTesting(.ready(expiresAt: Date().addingTimeInterval(6 * 3600 + 12 * 60)), key: "astrocompute:699475923216:SpaceportOrganizationAdmin")
        creds.seedProfileStatusForTesting(.notSignedIn(sessionName: "orion-labs"), key: "orion-labs:824177590102:ReadOnlyAccess")
        creds.seedStatusForTesting(.signedIn(expiresAt: Date().addingTimeInterval(6 * 3600 + 12 * 60), canRefresh: true), sessionName: "astrocompute")
        creds.seedStatusForTesting(.signedOut, sessionName: "orion-labs")

        let imds = IMDSModel()
        imds.setState(.active(port: 9678), forProfile: "ac:cp:org_admin")

        _appModel = State(initialValue: AppModel(initialPhase: .ready(folderURL)))
        _profilesModel = State(initialValue: profiles)
        _editorState = State(initialValue: EditorState())
        _credentialsModel = State(initialValue: creds)
        _imdsModel = State(initialValue: imds)
    }

    var body: some View {
        MainView(folderURL: folderURL, loadsProfilesOnAppear: false)
            .environment(appModel)
            .environment(profilesModel)
            .environment(editorState)
            .environment(credentialsModel)
            .environment(imdsModel)
    }
}
