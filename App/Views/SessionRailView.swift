import SwiftUI

struct SourceSidebarView: View {
    @Binding var selection: SourceSelection
    @Environment(ProfilesModel.self) private var profilesModel
    @Environment(IMDSModel.self) private var imdsModel

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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                sourceButton(
                    .all,
                    title: "All",
                    systemImage: "square.grid.2x2",
                    count: allObjectCount
                )

                Divider()
                    .padding(.vertical, 4)

                sourceButton(
                    .sessions,
                    title: "Sessions",
                    systemImage: "cloud",
                    count: sessionCount
                )
                .contextMenu { folderContextMenu(for: .sessions) }

                sourceButton(
                    .profiles,
                    title: "Profiles",
                    systemImage: "key",
                    count: profileCount
                )
                .contextMenu { folderContextMenu(for: .profiles) }

                sourceButton(
                    .imdsEndpoints,
                    title: "IMDS Endpoints",
                    systemImage: "antenna.radiowaves.left.and.right",
                    count: imdsEndpointCount
                )
                .contextMenu { folderContextMenu(for: .imdsEndpoints) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
        }
    }

    private func sourceButton(
        _ candidate: SourceSelection,
        title: String,
        systemImage: String,
        count: Int
    ) -> some View {
        Button {
            selection = candidate
        } label: {
            SourceSidebarRow(
                title: title,
                systemImage: systemImage,
                count: count
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(rowBackground(isSelected: selection == candidate), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private func folderContextMenu(for source: SourceSelection) -> some View {
        Button("New Folder") { }
            .disabled(true)
        Divider()
        Text("Folders arrive with metadata persistence")
    }

    private func rowBackground(isSelected: Bool) -> Color {
        isSelected ? Color.accentColor.opacity(0.18) : Color.clear
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
        imdsModel.endpointsByProfile.values.filter(\.isSourceSidebarEndpoint).count
    }
}

private struct SourceSidebarRow: View {
    let title: String
    let systemImage: String
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)

            Text(title)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text("\(count)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .accessibilityLabel("\(count) items")
        }
        .padding(.vertical, 2)
    }
}

private extension IMDSEndpointState {
    var isSourceSidebarEndpoint: Bool {
        switch self {
        case .inactive:
            return false
        case .starting, .active, .failed:
            return true
        }
    }
}

#Preview("Source Sidebar - populated") {
    SourceSidebarPreviewHarness()
}

private struct SourceSidebarPreviewHarness: View {
    @State private var selection: SourceSelection = .all
    @State private var profilesModel = ProfilesModel.previewLoaded(
        config: PreviewAWSFixtures.mockupConfig,
        credentials: PreviewAWSFixtures.mockupCredentials
    )
    @State private var imdsModel: IMDSModel

    init() {
        let imdsModel = IMDSModel()
        imdsModel.setState(.active(port: 9678), forProfile: "ac:cp:org_admin")
        _imdsModel = State(initialValue: imdsModel)
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
        .frame(width: 700, height: 500)
    }
}
