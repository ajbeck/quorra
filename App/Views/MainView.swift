import SwiftUI
import IAMIdentityCenter
import SwiftData

struct MainView: View {
    let folderURL: URL
    let loadsProfilesOnAppear: Bool
    @Environment(AppModel.self) private var appModel
    @Environment(ProfilesModel.self) private var profilesModel
    @Environment(CredentialsModel.self) private var credentialsModel
    @Environment(\.authBrowserPresenter) private var authBrowserPresenter
    @State private var sourceSelection: SourceSelection = .all
    @State private var selection: DetailSelection? = nil
    @State private var searchText = ""

    init(folderURL: URL, loadsProfilesOnAppear: Bool = true) {
        self.folderURL = folderURL
        self.loadsProfilesOnAppear = loadsProfilesOnAppear
    }

    var body: some View {
        NavigationSplitView {
            SourceSidebarView(selection: $sourceSelection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } content: {
            ObjectListView(
                sourceSelection: $sourceSelection,
                detailSelection: $selection,
                searchText: $searchText
            )
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 380)
        } detail: {
            DetailView(
                selection: $selection,
                sourceSelection: $sourceSelection,
                searchText: $searchText
            )
                .navigationSplitViewColumnWidth(min: 520, ideal: 760)
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search")
        .task(id: folderURL) {
            guard loadsProfilesOnAppear else { return }
            await profilesModel.load(folder: folderURL)
        }
        .onChange(of: sourceSelection) { _, _ in
            selection = nil
        }
        .onChange(of: searchText) { _, _ in
            selection = nil
        }
        .onChange(of: credentialsModel.inFlight) { oldValue, newValue in
            handleSignInPresentationChange(from: oldValue, to: newValue)
        }
    }

    private func handleSignInPresentationChange(
        from oldValue: [String: SignInProgress],
        to newValue: [String: SignInProgress]
    ) {
        for (sessionName, progress) in newValue where oldValue[sessionName] == nil {
            authBrowserPresenter.present(progress.verificationUriComplete)
            return
        }

        if oldValue.contains(where: { newValue[$0.key] == nil }) {
            authBrowserPresenter.dismiss()
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
        .environment(IMDSModel())
        .environment(\.authBrowserPresenter, AuthBrowserPresenter())
        .modelContainer(try! QuorraMetadataSchema.makeContainer(inMemory: true))
}

#Preview("Main – with sample data") {
    MainViewSampleDataHarness()
}

private struct MainViewSampleDataHarness: View {
    private static let previewEndpointID = UUID(uuidString: "00000000-0000-0000-0000-000000009678")!

    private let folderURL = URL(filePath: "/preview/.aws", directoryHint: .isDirectory)
    @State private var appModel: AppModel
    @State private var profilesModel: ProfilesModel
    @State private var editorState: EditorState
    @State private var credentialsModel: CredentialsModel
    @State private var imdsModel: IMDSModel
    private let metadataContainer: ModelContainer

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
        let metadataContainer = try! QuorraMetadataSchema.makeContainer(inMemory: true)
        let endpoint = IMDSEndpointDefinition(
            id: Self.previewEndpointID,
            name: "localhost:9678",
            profileName: "ac:cp:org_admin",
            port: 9678
        )
        metadataContainer.mainContext.insert(endpoint)
        try! metadataContainer.mainContext.save()
        imds.setState(.active(port: 9678), forEndpointID: endpoint.stableIDString)

        _appModel = State(initialValue: AppModel(initialPhase: .ready(folderURL)))
        _profilesModel = State(initialValue: profiles)
        _editorState = State(initialValue: EditorState())
        _credentialsModel = State(initialValue: creds)
        _imdsModel = State(initialValue: imds)
        self.metadataContainer = metadataContainer
    }

    var body: some View {
        MainView(folderURL: folderURL, loadsProfilesOnAppear: false)
            .environment(appModel)
            .environment(profilesModel)
            .environment(editorState)
            .environment(credentialsModel)
            .environment(imdsModel)
            .environment(\.authBrowserPresenter, AuthBrowserPresenter())
            .modelContainer(metadataContainer)
    }
}
