import SwiftUI
import SwiftData

struct SourceSidebarView: View {
    @Binding var selection: SourceSelection
    @Environment(ProfilesModel.self) private var profilesModel
    @Environment(IMDSModel.self) private var imdsModel
    @Environment(\.modelContext) private var modelContext
    @Query private var folders: [MetadataFolder]
    @Query private var assignments: [MetadataFolderAssignment]
    @Query private var endpointDefinitions: [IMDSEndpointDefinition]
    @State private var folderCreationRequest: FolderCreationRequest?
    @State private var folderRenameRequest: FolderRenameRequest?
    @State private var pendingFolderDeletion: FolderDeletionRequest?
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
        .sheet(item: $folderRenameRequest) { request in
            RenameMetadataFolderSheet(
                kind: request.kind,
                currentName: request.name,
                existingNames: folderNames(for: request.kind).subtracting([request.name])
            ) { name in
                try renameFolder(request, to: name)
            }
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { pendingFolderDeletion != nil },
                set: { if !$0 { pendingFolderDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingFolderDeletion {
                Button("Delete \(pendingFolderDeletion.name)", role: .destructive) {
                    deleteFolder(pendingFolderDeletion)
                }
            }
            Button("Cancel", role: .cancel) { pendingFolderDeletion = nil }
        } message: {
            if let pendingFolderDeletion {
                Text("Items assigned to \(pendingFolderDeletion.name) will stay in Quorra, but the folder and its assignments will be removed.")
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
            .contextMenu { folderRowContextMenu(for: folder) }
            .dropDestination(for: MetadataObjectDragPayload.self) { payloads, _ in
                assign(payloads, to: folder)
            }
        }
    }

    @ViewBuilder private func folderContextMenu(for kind: MetadataObjectKind) -> some View {
        Button {
            folderCreationRequest = FolderCreationRequest(kind: kind)
        } label: {
            Label("New Folder", systemImage: "folder.badge.plus")
        }
    }

    @ViewBuilder private func folderRowContextMenu(for folder: MetadataFolder) -> some View {
        Button {
            folderRenameRequest = FolderRenameRequest(folder: folder)
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Divider()

        Button(role: .destructive) {
            pendingFolderDeletion = FolderDeletionRequest(folder: folder)
        } label: {
            Label("Delete", systemImage: "trash")
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
        endpointDefinitions.count
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

    private var deletionTitle: String {
        guard let pendingFolderDeletion else { return "Delete Folder?" }
        return "Delete \(pendingFolderDeletion.name)?"
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

    private func renameFolder(_ request: FolderRenameRequest, to name: String) throws {
        guard let folder = folders.first(where: { $0.stableIDString == request.id }) else { return }
        folder.name = name
        folder.updatedAt = .now

        do {
            try modelContext.save()
            if case .folder(let kind, let folderID, _) = selection,
               folderID.uuidString == request.id {
                selection = .folder(kind: kind, folderID: folderID, name: name)
            }
        } catch {
            folderActionError = error.localizedDescription
            throw error
        }
    }

    private func deleteFolder(_ request: FolderDeletionRequest) {
        guard let folder = folders.first(where: { $0.stableIDString == request.id }) else {
            pendingFolderDeletion = nil
            return
        }

        for assignment in assignments where assignment.folderIDString == request.id {
            modelContext.delete(assignment)
        }
        modelContext.delete(folder)

        do {
            try modelContext.save()
            if case .folder(_, let folderID, _) = selection,
               folderID.uuidString == request.id {
                selection = parentSelection(for: request.kind)
            }
            pendingFolderDeletion = nil
        } catch {
            folderActionError = error.localizedDescription
        }
    }

    private func assign(_ payloads: [MetadataObjectDragPayload], to folder: MetadataFolder) -> Bool {
        let compatiblePayloads = payloads.filter { $0.kind == folder.kind }
        guard !compatiblePayloads.isEmpty else { return false }

        do {
            for payload in compatiblePayloads {
                if let assignment = assignments.first(where: {
                    $0.objectKind == payload.kind && $0.objectID == payload.objectID
                }) {
                    assignment.move(to: folder.stableID)
                } else {
                    modelContext.insert(MetadataFolderAssignment(
                        objectKind: payload.kind,
                        objectID: payload.objectID,
                        folderID: folder.stableID
                    ))
                }
            }
            try modelContext.save()
            return true
        } catch {
            folderActionError = error.localizedDescription
            return false
        }
    }

    private func parentSelection(for kind: MetadataObjectKind) -> SourceSelection {
        switch kind {
        case .session:
            return .sessions
        case .profile:
            return .profiles
        case .imdsEndpoint:
            return .imdsEndpoints
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

private struct FolderRenameRequest: Identifiable {
    let id: String
    let kind: MetadataObjectKind
    let name: String

    init(folder: MetadataFolder) {
        id = folder.stableIDString
        kind = folder.kind
        name = folder.name
    }
}

private struct FolderDeletionRequest: Identifiable {
    let id: String
    let kind: MetadataObjectKind
    let name: String

    init(folder: MetadataFolder) {
        id = folder.stableIDString
        kind = folder.kind
        name = folder.name
    }
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

private struct RenameMetadataFolderSheet: View {
    let kind: MetadataObjectKind
    let currentName: String
    let existingNames: Set<String>
    let onRename: (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var validationMessage: String?

    init(
        kind: MetadataObjectKind,
        currentName: String,
        existingNames: Set<String>,
        onRename: @escaping (String) throws -> Void
    ) {
        self.kind = kind
        self.currentName = currentName
        self.existingNames = existingNames
        self.onRename = onRename
        _name = State(initialValue: currentName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Rename Folder")
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
                Button("Rename") { rename() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func rename() {
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
            try onRename(trimmedName)
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}

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
