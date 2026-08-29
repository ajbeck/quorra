import SwiftUI
import AWSConfigINI
import QuorraAppLogic
import SwiftData

struct DetailView: View {
    @Binding var selection: DetailSelection?
    @Binding var sourceSelection: SourceSelection
    @Binding var searchText: String
    @Environment(AppModel.self) private var appModel
    @Environment(ProfilesModel.self) private var profilesModel

    var body: some View {
        switch (profilesModel.loadState, selection) {
        case (.idle, _), (.loading, _):
            ProgressView().controlSize(.small)
        case (.failed(let err), _):
            ContentUnavailableView(
                "Couldn't load profiles",
                systemImage: "exclamationmark.triangle",
                description: Text(err.localizedDescription)
            )
        case (.loaded, .none):
            if profilesModel.groups == .empty {
                ContentUnavailableView {
                    Label("No profiles yet", systemImage: "folder")
                } description: {
                    Text("Quorra will read profiles from ~/.aws/config and ~/.aws/credentials. Add profiles using the AWS CLI to see them here.")
                }
            } else {
                ContentUnavailableView("Select an item", systemImage: "sidebar.leading")
            }
        case (.loaded, .profile(let name)):
            if let node = profilesModel.findProfile(named: name) {
                ProfileDetailView(
                    node: node,
                    detailSelection: $selection,
                    sourceSelection: $sourceSelection,
                    searchText: $searchText
                )
            } else {
                ContentUnavailableView("Profile not found", systemImage: "questionmark.circle")
            }
        case (.loaded, .session(let name)):
            if let node = profilesModel.findSession(named: name) {
                SessionDetailView(node: node)
            } else {
                ContentUnavailableView("Session not found", systemImage: "questionmark.circle")
            }
        case (.loaded, .imds(let endpointID)):
            IMDSDetailView(endpointID: endpointID)
        }
    }

}

#if DEBUG

#Preview("Detail – loaded, no selection") {
    DetailViewPreviewHarness(selection: nil)
}

#Preview("Detail – loaded, profile selected") {
    DetailViewPreviewHarness(selection: .profile(name: "default"))
}

#Preview("Detail – Read Only mode") {
    DetailViewPreviewHarness(
        selection: .profile(name: "default"),
        mode: .readOnly
    )
}

#Preview("Detail – IMDS selected") {
    DetailViewPreviewHarness(selection: .imds(endpointID: "00000000-0000-0000-0000-000000009679"))
}

#Preview("Detail – no profiles yet") {
    DetailViewPreviewHarness(selection: nil, forceEmpty: true)
}

private struct DetailViewPreviewHarness: View {
    let initialSelection: DetailSelection?
    let mode: ManagedMode
    let forceEmpty: Bool
    @State private var selection: DetailSelection?
    @State private var sourceSelection: SourceSelection = .all
    @State private var searchText = ""
    @State private var appModel: AppModel
    @State private var profilesModel = ProfilesModel()
    @State private var editorState = EditorState()
    @State private var imdsModel = IMDSModel()
    private let metadataContainer: ModelContainer

    init(selection: DetailSelection?, mode: ManagedMode = .managed, forceEmpty: Bool = false) {
        self.initialSelection = selection
        self.mode = mode
        self.forceEmpty = forceEmpty
        let tmp = URL(filePath: "/nonexistent/aws-folder")
        let metadataContainer = try! QuorraMetadataSchema.makeContainer(inMemory: true)
        if case .imds(let endpointID) = selection,
           let uuid = UUID(uuidString: endpointID) {
            metadataContainer.mainContext.insert(IMDSEndpointDefinition(
                id: uuid,
                name: "localhost:9678",
                profileName: "default",
                port: 9678
            ))
            try! metadataContainer.mainContext.save()
        }

        _appModel = State(initialValue: AppModel(initialPhase: .ready(tmp), initialMode: mode))
        _selection = State(initialValue: selection)
        self.metadataContainer = metadataContainer
    }

    var body: some View {
        DetailView(
            selection: $selection,
            sourceSelection: $sourceSelection,
            searchText: $searchText
        )
            .environment(appModel)
            .environment(profilesModel)
            .environment(editorState)
            .environment(CredentialsModel(service: PreviewIdentityCenterService()))
            .environment(imdsModel)
            .modelContainer(metadataContainer)
            .task {
                let tmp = FileManager.default.temporaryDirectory
                    .appending(path: UUID().uuidString, directoryHint: .isDirectory)
                try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                if !forceEmpty {
                    try? sampleConfig.write(
                        to: tmp.appending(path: "config", directoryHint: .notDirectory),
                        atomically: true,
                        encoding: .utf8
                    )
                }
                appModel = AppModel(initialPhase: .ready(tmp), initialMode: mode)
                await profilesModel.load(folder: tmp)
                if let initialSelection {
                    selection = initialSelection
                }
            }
    }

    private var sampleConfig: String {
        """
        [sso-session acme]
        sso_start_url = https://acme.awsapps.com/start
        sso_region = us-east-1
        sso_registration_scopes = sso:account:access

        [default]
        sso_session = acme
        sso_account_id = 412903117204
        sso_role_name = AdministratorAccess
        region = us-east-1
        output = json

        [profile assume-billing]
        role_arn = arn:aws:iam::412903117204:role/Billing
        source_profile = default
        """
    }
}

#endif
