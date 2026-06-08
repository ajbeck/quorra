import SwiftUI
import SwiftData

struct SourceSidebarView: View {
    @Binding var selection: SourceSelection
    @Environment(ProfilesModel.self) private var profilesModel
    @Environment(IMDSModel.self) private var imdsModel
    @Environment(\.modelContext) private var modelContext
    @Query private var folders: [MetadataFolder]
    @Query private var assignments: [MetadataFolderAssignment]
    @State private var folderCreationRequest: FolderCreationRequest?
    @State private var folderActionError: String?

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
                .contextMenu { folderContextMenu(for: .session) }
                folderRows(for: .session)

                sourceButton(
                    .profiles,
                    title: "Profiles",
                    systemImage: "key",
                    count: profileCount
                )
                .contextMenu { folderContextMenu(for: .profile) }
                folderRows(for: .profile)

                sourceButton(
                    .imdsEndpoints,
                    title: "IMDS Endpoints",
                    systemImage: "antenna.radiowaves.left.and.right",
                    count: imdsEndpointCount
                )
                .contextMenu { folderContextMenu(for: .imdsEndpoint) }
                folderRows(for: .imdsEndpoint)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
        }
        .sheet(item: $folderCreationRequest) { request in
            AddMetadataFolderSheet(kind: request.kind, existingNames: folderNames(for: request.kind)) { name in
                try createFolder(kind: request.kind, name: name)
            }
        }
        .alert(
            "Couldn't update folders",
            isPresented: Binding(
                get: { folderActionError != nil },
                set: { if !$0 { folderActionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { folderActionError = nil }
        } message: {
            Text(folderActionError ?? "")
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

    @ViewBuilder private func folderRows(for kind: MetadataObjectKind) -> some View {
        ForEach(sortedFolders(for: kind), id: \.stableIDString) { folder in
            sourceButton(
                .folder(kind: kind, folderID: folder.stableID, name: folder.name),
                title: folder.name,
                systemImage: "folder",
                count: folderCount(folder)
            )
            .padding(.leading, 18)
        }
    }

    @ViewBuilder private func folderContextMenu(for kind: MetadataObjectKind) -> some View {
        Button {
            folderCreationRequest = FolderCreationRequest(kind: kind)
        } label: {
            Label("New Folder", systemImage: "folder.badge.plus")
        }
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

    private func sortedFolders(for kind: MetadataObjectKind) -> [MetadataFolder] {
        folders
            .filter { $0.kind == kind }
            .sorted {
                if $0.sortIndex != $1.sortIndex {
                    return $0.sortIndex < $1.sortIndex
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    private func folderNames(for kind: MetadataObjectKind) -> Set<String> {
        Set(folders.filter { $0.kind == kind }.map(\.name))
    }

    private func folderCount(_ folder: MetadataFolder) -> Int {
        assignments.filter { $0.folderIDString == folder.stableIDString }.count
    }

    private func createFolder(kind: MetadataObjectKind, name: String) throws {
        let sortIndex = (sortedFolders(for: kind).map(\.sortIndex).max() ?? -1) + 1
        modelContext.insert(MetadataFolder(kind: kind, name: name, sortIndex: sortIndex))
        do {
            try modelContext.save()
        } catch {
            folderActionError = error.localizedDescription
            throw error
        }
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

private struct FolderCreationRequest: Identifiable {
    let id = UUID()
    let kind: MetadataObjectKind
}

private struct AddMetadataFolderSheet: View {
    let kind: MetadataObjectKind
    let existingNames: Set<String>
    let onCreate: (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Folder")
                .font(.title3.weight(.semibold))

            TextField("\(kind.title) folder name", text: $name)

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") { add() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func add() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationMessage = "Folder name is required."
            return
        }
        guard !existingNames.contains(trimmedName) else {
            validationMessage = "A folder named \(trimmedName) already exists."
            return
        }

        do {
            try onCreate(trimmedName)
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
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
        .modelContainer(try! QuorraMetadataSchema.makeContainer(inMemory: true))
        .frame(width: 700, height: 500)
    }
}
