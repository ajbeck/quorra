import SwiftUI
import IAMIdentityCenter
import QuorraAppLogic
import SwiftData

struct MainView: View {
    let folderURL: URL
    let loadsProfilesOnAppear: Bool
    @Environment(AppModel.self) private var appModel
    @Environment(ProfilesModel.self) private var profilesModel
    @Environment(CredentialsModel.self) private var credentialsModel
    @Environment(\.authBrowserPresenter) private var authBrowserPresenter
    @State private var sourceSelection: SourceSelection
    @State private var selection: DetailSelection?
    @State private var searchText: String

    init(
        folderURL: URL,
        loadsProfilesOnAppear: Bool = true,
        initialSourceSelection: SourceSelection = .all,
        initialDetailSelection: DetailSelection? = nil,
        initialSearchText: String = ""
    ) {
        self.folderURL = folderURL
        self.loadsProfilesOnAppear = loadsProfilesOnAppear
        _sourceSelection = State(initialValue: initialSourceSelection)
        _selection = State(initialValue: initialDetailSelection)
        _searchText = State(initialValue: initialSearchText)
    }

    var body: some View {
        NavigationSplitView {
            SourceSidebarView(selection: navigationSourceSelection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } content: {
            ObjectListView(
                sourceSelection: $sourceSelection,
                detailSelection: $selection,
                searchText: navigationSearchText
            )
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 380)
        } detail: {
            DetailView(
                selection: $selection,
                sourceSelection: $sourceSelection,
                searchText: navigationSearchText
            )
                .navigationSplitViewColumnWidth(min: 520, ideal: 760)
        }
        .searchable(text: navigationSearchText, placement: .toolbar, prompt: "Search")
        .task(id: folderURL) {
            guard loadsProfilesOnAppear else { return }
            await profilesModel.load(folder: folderURL)
            guard case .loaded = profilesModel.loadState else { return }
            await credentialsModel.initializeStatuses(
                forSessions: profilesModel.groups.ssoSessions.map(\.id)
            )
        }
        .onChange(of: credentialsModel.inFlight) { oldValue, newValue in
            handleSignInPresentationChange(from: oldValue, to: newValue)
        }
    }

    /// Changes the source and clears the detail in the same SwiftUI transaction.
    /// Keeping those mutations together avoids an intermediate frame where the new
    /// source is asked to render the previous source's selection.
    private var navigationSourceSelection: Binding<SourceSelection> {
        Binding(
            get: { sourceSelection },
            set: { newSelection in
                guard newSelection != sourceSelection else { return }
                sourceSelection = newSelection
                selection = nil
            }
        )
    }

    /// Search changes also invalidate the selected row. Updating both values in the
    /// binding setter avoids a second render pass from a trailing `onChange` callback.
    private var navigationSearchText: Binding<String> {
        Binding(
            get: { searchText },
            set: { newSearchText in
                guard newSearchText != searchText else { return }
                searchText = newSearchText
                selection = nil
            }
        )
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

#if DEBUG

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

#Preview("Main – Profiles source") {
    MainViewSampleDataHarness(sourceSelection: .profiles)
}

#Preview("Main – IMDS source") {
    MainViewSampleDataHarness(sourceSelection: .imdsEndpoints)
}

#Preview("Main – Searching profiles") {
    MainViewSampleDataHarness(sourceSelection: .profiles, searchText: "mgmt")
}

#Preview("Main – selected profile") {
    MainViewSampleDataHarness(
        sourceSelection: .profiles,
        detailSelection: .profile(name: "ac:cp:org_admin")
    )
}

#Preview("quorra") {
    MainViewSampleDataHarness(
        sourceSelection: .profiles,
        detailSelection: .profile(name: "ac:cp:org_admin")
    )
}

private struct MainViewSampleDataHarness: View {
    private static let previewEndpointID = UUID(uuidString: "00000000-0000-0000-0000-000000009678")!

    private let folderURL = URL(filePath: "/preview/.aws", directoryHint: .isDirectory)
    private let initialSourceSelection: SourceSelection
    private let initialDetailSelection: DetailSelection?
    private let initialSearchText: String
    @State private var appModel: AppModel
    @State private var profilesModel: ProfilesModel
    @State private var editorState: EditorState
    @State private var credentialsModel: CredentialsModel
    @State private var imdsModel: IMDSModel
    private let metadataContainer: ModelContainer

    init(
        sourceSelection: SourceSelection = .all,
        detailSelection: DetailSelection? = nil,
        searchText: String = ""
    ) {
        initialSourceSelection = sourceSelection
        initialDetailSelection = detailSelection
        initialSearchText = searchText
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
        MainView(
            folderURL: folderURL,
            loadsProfilesOnAppear: false,
            initialSourceSelection: initialSourceSelection,
            initialDetailSelection: initialDetailSelection,
            initialSearchText: initialSearchText
        )
            .environment(appModel)
            .environment(profilesModel)
            .environment(editorState)
            .environment(credentialsModel)
            .environment(imdsModel)
            .environment(\.authBrowserPresenter, AuthBrowserPresenter())
            .modelContainer(metadataContainer)
    }
}

#endif
