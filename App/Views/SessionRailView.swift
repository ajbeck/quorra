import SwiftUI
import SwiftData
import QuorraAppLogic
import QuorraProfiles

struct SourceSidebarView: View {
    @Binding var selection: SourceSelection
    @Environment(ProfilesModel.self) private var profilesModel
    @Environment(IMDSModel.self) private var imdsModel
    @Query private var endpointDefinitions: [IMDSEndpointDefinition]

    var body: some View {
        switch profilesModel.loadState {
        case .idle, .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView(
                "Failed to Load Sources",
                systemImage: "exclamationmark.triangle",
                description: Text("Quorra couldn't read your AWS configuration.")
            )
        case .loaded:
            sourceList
        }
    }

    private var sourceList: some View {
        List(selection: $selection) {
            Section {
                SourceSidebarRow(title: "All", systemImage: "square.grid.2x2")
                    .badge(allObjectCount)
                    .tag(SourceSelection.all)
            }

            Section {
                SourceSidebarRow(title: MetadataObjectKind.session.title, systemImage: MetadataObjectKind.session.systemImage)
                    .badge(sessionCount)
                    .tag(SourceSelection.sessions)
                SourceSidebarRow(title: MetadataObjectKind.profile.title, systemImage: MetadataObjectKind.profile.systemImage)
                    .badge(profileCount)
                    .tag(SourceSelection.profiles)
                SourceSidebarRow(title: MetadataObjectKind.imdsEndpoint.title, systemImage: MetadataObjectKind.imdsEndpoint.systemImage)
                    .badge(imdsEndpointCount)
                    .tag(SourceSelection.imdsEndpoints)
            }
        }
        .listStyle(.sidebar)
        .badgeProminence(.decreased)
    }

    private var allObjectCount: Int {
        sessionCount + profileCount + imdsEndpointCount
    }

    private var sessionCount: Int {
        profilesModel.groups.ssoSessions.count
    }

    private var profileCount: Int {
        profilesModel.groups.flatProfiles.count
    }

    private var imdsEndpointCount: Int {
        endpointDefinitions.count
    }
}

private struct SourceSidebarRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)

            Text(title)
                .lineLimit(1)
        }
    }
}

#if DEBUG

#Preview("Source Sidebar - populated") {
    SourceSidebarPreviewHarness()
}

private struct SourceSidebarPreviewHarness: View {
    private static let previewEndpointID = UUID(uuidString: "00000000-0000-0000-0000-000000009678")!

    @State private var selection: SourceSelection = .all
    @State private var profilesModel = ProfilesModel.previewLoaded(
        config: PreviewAWSFixtures.mockupConfig,
        credentials: PreviewAWSFixtures.mockupCredentials
    )
    @State private var imdsModel: IMDSModel
    private let metadataContainer: ModelContainer

    init() {
        let imdsModel = IMDSModel()
        let metadataContainer = try! QuorraMetadataSchema.makeContainer(inMemory: true)
        let endpoint = IMDSEndpointDefinition(
            id: Self.previewEndpointID,
            name: "localhost:9678",
            profileName: "ac:cp:org_admin",
            port: 9678
        )
        metadataContainer.mainContext.insert(endpoint)
        try! metadataContainer.mainContext.save()
        imdsModel.setState(.active(port: 9678), forEndpointID: endpoint.stableIDString)

        _imdsModel = State(initialValue: imdsModel)
        self.metadataContainer = metadataContainer
    }

    var body: some View {
        NavigationSplitView {
            SourceSidebarView(selection: $selection)
        } detail: {
            Text("Detail")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(profilesModel)
        .environment(imdsModel)
        .modelContainer(metadataContainer)
        .frame(width: 700, height: 500)
    }
}

#endif
