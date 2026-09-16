import SwiftUI
import SwiftData
import QuorraAppLogic

struct SourceSidebarView: View {
    @Binding var selection: SourceSelection
    @Query private var sessionDefinitions: [SessionDefinition]
    @Query private var profileDefinitions: [ProfileDefinition]
    @Query private var endpointDefinitions: [IMDSEndpointDefinition]

    var body: some View {
        List(selection: $selection) {
            Section {
                SourceSidebarRow(title: "All", systemImage: "square.grid.2x2")
                    .badge(allObjectCount)
                    .tag(SourceSelection.all)
            }

            Section {
                SourceSidebarRow(title: MetadataObjectKind.session.title, systemImage: MetadataObjectKind.session.systemImage)
                    .badge(sessionDefinitions.count)
                    .tag(SourceSelection.sessions)
                SourceSidebarRow(title: MetadataObjectKind.profile.title, systemImage: MetadataObjectKind.profile.systemImage)
                    .badge(profileDefinitions.count)
                    .tag(SourceSelection.profiles)
                SourceSidebarRow(title: MetadataObjectKind.imdsEndpoint.title, systemImage: MetadataObjectKind.imdsEndpoint.systemImage)
                    .badge(endpointDefinitions.count)
                    .tag(SourceSelection.imdsEndpoints)
            }
        }
        .listStyle(.sidebar)
        .badgeProminence(.decreased)
    }

    private var allObjectCount: Int {
        sessionDefinitions.count + profileDefinitions.count + endpointDefinitions.count
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
    @State private var selection: SourceSelection = .all
    private let metadataContainer = PreviewIdentityFixtures.makeContainer(seedsEndpoint: true)

    var body: some View {
        NavigationSplitView {
            SourceSidebarView(selection: $selection)
        } detail: {
            Text("Detail")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .modelContainer(metadataContainer)
        .frame(width: 700, height: 500)
    }
}

#endif
