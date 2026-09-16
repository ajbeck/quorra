import SwiftUI
import QuorraAppLogic
import SwiftData

struct DetailView: View {
    @Binding var selection: DetailSelection?
    @Binding var sourceSelection: SourceSelection
    @Binding var searchText: String
    @Query private var sessionDefinitions: [SessionDefinition]
    @Query private var profileDefinitions: [ProfileDefinition]

    /// Each item gets explicit identity (`.id`). The `switch` alone keeps the same view across
    /// selections of the same kind, so its state (the edit draft, the credentials card's values)
    /// would belong to the previous item for one frame and the detail would draw twice. Apple's
    /// `id(_:)` reference: "When the proxy value specified by the id parameter changes, the identity
    /// of the view — for example, its state — is reset." (post-1.0 D3)
    var body: some View {
        switch selection {
        case .none:
            if sessionDefinitions.isEmpty {
                ContentUnavailableView {
                    Label("No sessions yet", systemImage: "cloud")
                } description: {
                    Text("Add an IAM Identity Center session, sign in, and create profiles for the accounts and roles it grants you.")
                }
            } else {
                ContentUnavailableView("Select an item", systemImage: "sidebar.leading")
            }
        case .profile(let name):
            if let profile = profileDefinitions.first(where: { $0.name == name }) {
                ProfileDetailView(
                    profile: profile,
                    detailSelection: $selection,
                    sourceSelection: $sourceSelection,
                    searchText: $searchText
                )
                .id(name)
            } else {
                ContentUnavailableView("Profile not found", systemImage: "questionmark.circle")
            }
        case .session(let name):
            if let session = sessionDefinitions.first(where: { $0.name == name }) {
                SessionDetailView(session: session)
                    .id(name)
            } else {
                ContentUnavailableView("Session not found", systemImage: "questionmark.circle")
            }
        case .imds(let endpointID):
            IMDSDetailView(
                endpointID: endpointID,
                detailSelection: $selection,
                sourceSelection: $sourceSelection,
                searchText: $searchText
            )
        }
    }

}

#if DEBUG

#Preview("Detail – no selection") {
    DetailViewPreviewHarness(selection: nil)
}

#Preview("Detail – profile selected") {
    DetailViewPreviewHarness(selection: .profile(name: "ac:cp:org_admin"))
}

#Preview("Detail – session selected") {
    DetailViewPreviewHarness(selection: .session(name: "astrocompute"))
}

#Preview("Detail – IMDS selected") {
    DetailViewPreviewHarness(selection: .imds(endpointID: PreviewIdentityFixtures.endpointID.uuidString))
}

#Preview("Detail – no sessions yet") {
    DetailViewPreviewHarness(selection: nil, forceEmpty: true)
}

private struct DetailViewPreviewHarness: View {
    @State private var selection: DetailSelection?
    @State private var sourceSelection: SourceSelection = .all
    @State private var searchText = ""
    @State private var editorState = EditorState()
    @State private var imdsModel = IMDSModel()
    private let metadataContainer: ModelContainer

    init(selection: DetailSelection?, forceEmpty: Bool = false) {
        _selection = State(initialValue: selection)
        metadataContainer = forceEmpty
            ? try! QuorraMetadataSchema.makeContainer(inMemory: true)
            : PreviewIdentityFixtures.makeContainer(seedsEndpoint: true)
    }

    var body: some View {
        DetailView(
            selection: $selection,
            sourceSelection: $sourceSelection,
            searchText: $searchText
        )
            .environment(editorState)
            .environment(CredentialsModel(service: PreviewIdentityCenterService()))
            .environment(imdsModel)
            .environment(IMDSProxyController())
            .environment(AppRuntimeCoordinator.preview())
            .environment(DefaultIMDSNotificationCoordinator())
            .modelContainer(metadataContainer)
    }
}

#endif
