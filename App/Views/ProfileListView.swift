import SwiftUI
import AWSConfigINI
import IAMIdentityCenter
import SwiftData

struct ObjectListView: View {
    @Binding var sourceSelection: SourceSelection
    @Binding var detailSelection: DetailSelection?
    @Binding var searchText: String
    @Environment(AppModel.self) private var appModel
    @Environment(ProfilesModel.self) private var profilesModel
    @Environment(IMDSModel.self) private var imdsModel
    @Environment(\.modelContext) private var modelContext
    @Query private var folderAssignments: [MetadataFolderAssignment]
    @Query private var endpointDefinitions: [IMDSEndpointDefinition]

    @State private var presentedSheet: CreationSheet?
    @State private var pendingDeletion: ObjectListItem?
    @State private var actionError: AWSConfigINIError?
    @State private var isPresentingActionError = false

    var body: some View {
        switch profilesModel.loadState {
        case .idle, .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView(
                "Failed to Load Items",
                systemImage: "exclamationmark.triangle",
                description: Text("Quorra couldn't read your AWS configuration.")
            )
        case .loaded:
            loadedView
        }
    }

    private var loadedView: some View {
        VStack(spacing: 0) {
            header
            objectListContainer
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .session:
                AddSessionSheet(existingNames: Set(sortedSessions.map(\.id))) { name, session in
                    try await profilesModel.createSession(named: name, session: session, mode: appModel.mode)
                    searchText = ""
                    sourceSelection = .sessions
                    detailSelection = .session(name: name)
                }
            case .profile:
                AddProfileSheet(
                    existingNames: Set(profileItems.map(\.id)),
                    sessions: sortedSessions,
                    defaultSessionName: nil
                ) { name, profile in
                    try await profilesModel.createProfile(named: name, profile: profile, mode: appModel.mode)
                    searchText = ""
                    sourceSelection = .profiles
                    detailSelection = .profile(name: name)
                }
            case .imdsEndpoint:
                AddIMDSEndpointSheet(
                    existingNames: Set(endpointDefinitions.map(\.name)),
                    usedPorts: Set(endpointDefinitions.map(\.port)),
                    profiles: profileItems.map(\.node)
                ) { endpoint in
                    modelContext.insert(endpoint)
                    try modelContext.save()
                    searchText = ""
                    sourceSelection = .imdsEndpoints
                    detailSelection = .imds(endpointID: endpoint.stableIDString, profileName: endpoint.profileName)
                }
            }
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingDeletion {
                Button(deletionButtonTitle(for: pendingDeletion), role: .destructive) {
                    Task { await delete(pendingDeletion) }
                }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            if let pendingDeletion {
                Text(deletionMessage(for: pendingDeletion))
            }
        }
        .alert(
            "Couldn't update items",
            isPresented: $isPresentingActionError,
            presenting: actionError
        ) { _ in
            Button("OK", role: .cancel) { }
        } message: { error in
            Text([error.errorDescription, error.recoverySuggestion]
                .compactMap { $0 }.joined(separator: "\n\n"))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(isSearching ? "Searching" : sourceSelection.title)
                .font(.headline.weight(.semibold))
                .lineLimit(1)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var objectListContainer: some View {
        VStack(spacing: 0) {
            listContent
                .frame(maxHeight: .infinity)

            Divider()
            objectMutationBar
        }
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.10))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private var listContent: some View {
        if visibleItems.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if case .all = sourceSelection {
                        objectSection("Sessions", items: filteredSessionItems)
                        objectSection("Profiles", items: filteredProfileItems)
                        objectSection("IMDS Endpoints", items: filteredIMDSItems)
                    } else {
                        ForEach(visibleItems) { item in
                            objectButton(for: item)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder private func objectSection(_ title: String, items: [ObjectListItem]) -> some View {
        if !items.isEmpty {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 2)

            ForEach(items) { item in
                objectButton(for: item)
            }
        }
    }

    private func objectButton(for item: ObjectListItem) -> some View {
        Button {
            detailSelection = item.detailSelection
        } label: {
            ObjectListRow(item: item)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            rowBackground(isSelected: detailSelection == item.detailSelection),
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    private var objectMutationBar: some View {
        HStack(spacing: 0) {
            Menu {
                Button {
                    presentedSheet = .session
                } label: {
                    Label("New Session", systemImage: "cloud")
                }
                .disabled(isReadOnly)

                Button {
                    presentedSheet = .profile
                } label: {
                    Label("New Profile", systemImage: "key")
                }
                .disabled(isReadOnly)

                Button {
                    presentedSheet = .imdsEndpoint
                } label: {
                    Label("New IMDS Endpoint", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(profileItems.isEmpty)
            } label: {
                Label("Add Item", systemImage: "plus")
            }
            .menuStyle(.button)
            .controlSize(.small)
            .labelStyle(.iconOnly)
            .help("Add session, profile, or IMDS endpoint")

            Button {
                if let selectedItem {
                    pendingDeletion = selectedItem
                }
            } label: {
                Label("Remove Item", systemImage: "minus")
            }
            .controlSize(.small)
            .labelStyle(.iconOnly)
            .disabled(!canDeleteSelectedItem)
            .help(removeHelp)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Color.secondary.opacity(0.10))
    }

    @ViewBuilder private var emptyState: some View {
        if isSearching {
            ContentUnavailableView.search(text: searchText)
        } else {
            ContentUnavailableView(
                "No Items",
                systemImage: sourceSelection.emptySystemImage,
                description: Text(sourceSelection.emptyDescription)
            )
        }
    }

    private func rowBackground(isSelected: Bool) -> Color {
        isSelected ? Color.accentColor.opacity(0.18) : Color.clear
    }

    private var sortedSessions: [SSOSessionNode] {
        profilesModel.groups.ssoSessions.sorted {
            $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }

    private var profileItems: [SidebarProfileItem] {
        profilesModel.groups.flatProfiles
    }

    private var imdsItems: [TemporaryIMDSEndpointItem] {
        let definitionProfileNames = Set(endpointDefinitions.map(\.profileName))
        let persistedItems = endpointDefinitions.map { definition in
            TemporaryIMDSEndpointItem(
                endpointID: definition.stableIDString,
                name: definition.name,
                profileName: definition.profileName,
                port: definition.port,
                state: imdsModel.state(forProfile: definition.profileName),
                profile: profilesModel.findProfile(named: definition.profileName),
                isPersisted: true
            )
        }

        let runtimeOnlyItems = imdsModel.endpointsByProfile
            .compactMap { profileName, state -> TemporaryIMDSEndpointItem? in
                guard state.isConcreteEndpoint, !definitionProfileNames.contains(profileName) else { return nil }
                return TemporaryIMDSEndpointItem(
                    endpointID: profileName,
                    name: nil,
                    profileName: profileName,
                    port: state.port,
                    state: state,
                    profile: profilesModel.findProfile(named: profileName),
                    isPersisted: false
                )
            }

        return (persistedItems + runtimeOnlyItems)
            .sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    private var sessionItems: [ObjectListItem] {
        sortedSessions.map { .session($0) }
    }

    private var profileObjectItems: [ObjectListItem] {
        profileItems.map { .profile($0) }
    }

    private var imdsObjectItems: [ObjectListItem] {
        imdsItems.map { .imds($0) }
    }

    private var filteredSessionItems: [ObjectListItem] {
        filtered(sessionItems)
    }

    private var filteredProfileItems: [ObjectListItem] {
        filtered(profileObjectItems)
    }

    private var filteredIMDSItems: [ObjectListItem] {
        filtered(imdsObjectItems)
    }

    private var sourceItems: [ObjectListItem] {
        switch sourceSelection {
        case .all:
            return sessionItems + profileObjectItems + imdsObjectItems
        case .sessions:
            return sessionItems
        case .profiles:
            return profileObjectItems
        case .imdsEndpoints:
            return imdsObjectItems
        case .folder(let kind, let folderID, _):
            return assignedItems(kind: kind, folderID: folderID)
        }
    }

    private var visibleItems: [ObjectListItem] {
        switch sourceSelection {
        case .all:
            return filteredSessionItems + filteredProfileItems + filteredIMDSItems
        case .sessions:
            return filteredSessionItems
        case .profiles:
            return filteredProfileItems
        case .imdsEndpoints:
            return filteredIMDSItems
        case .folder:
            return filtered(sourceItems)
        }
    }

    private func assignedItems(kind: MetadataObjectKind, folderID: UUID) -> [ObjectListItem] {
        let assignedIDs = Set(
            folderAssignments
                .filter { $0.objectKind == kind && $0.folderID == folderID }
                .map(\.objectID)
        )

        return items(for: kind).filter { assignedIDs.contains($0.objectID) }
    }

    private func items(for kind: MetadataObjectKind) -> [ObjectListItem] {
        switch kind {
        case .session:
            return sessionItems
        case .profile:
            return profileObjectItems
        case .imdsEndpoint:
            return imdsObjectItems
        }
    }

    private func filtered(_ items: [ObjectListItem]) -> [ObjectListItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.searchText.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedItem: ObjectListItem? {
        guard let detailSelection else { return nil }
        return sourceItems.first { $0.detailSelection == detailSelection }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var subtitle: String {
        if isSearching {
            return "\(sourceSelection.title), \(visibleItems.count) \(visibleItems.count == 1 ? "result" : "results")"
        }

        let count = sourceItems.count
        return "\(count) \(count == 1 ? "item" : "items")"
    }

    private var isReadOnly: Bool {
        appModel.mode == .readOnly
    }

    private var canDeleteSelectedItem: Bool {
        guard let selectedItem else { return false }
        switch selectedItem {
        case .session, .profile:
            return !isReadOnly
        case .imds:
            return true
        }
    }

    private var removeHelp: String {
        guard let selectedItem else { return "Select an item to remove." }
        switch selectedItem {
        case .session:
            return isReadOnly ? "Switch to Edit & Manage mode to remove sessions." : "Remove selected session"
        case .profile:
            return isReadOnly ? "Switch to Edit & Manage mode to remove profiles." : "Remove selected profile"
        case .imds:
            return "Remove selected IMDS endpoint"
        }
    }

    private var deletionTitle: String {
        guard let pendingDeletion else { return "Remove item?" }
        switch pendingDeletion {
        case .session:
            return "Delete SSO session?"
        case .profile:
            return "Delete profile?"
        case .imds:
            return "Remove IMDS endpoint?"
        }
    }

    private func deletionButtonTitle(for item: ObjectListItem) -> String {
        switch item {
        case .session(let session):
            return "Delete \(session.id)"
        case .profile(let profile):
            return "Delete \(profile.id)"
        case .imds(let endpoint):
            return "Remove \(endpoint.title)"
        }
    }

    private func deletionMessage(for item: ObjectListItem) -> String {
        switch item {
        case .session(let session):
            return "This removes the [sso-session \(session.id)] section. Profiles that reference it remain in your config."
        case .profile(let profile):
            return "This removes \(profile.id) from your AWS config and credentials files. Any running IMDS endpoint for this profile will be stopped."
        case .imds(let endpoint):
            if endpoint.isPersisted {
                return "This removes the \(endpoint.title) IMDS endpoint definition from Quorra. It does not change ~/.aws/config."
            }
            return "This stops the temporary IMDS endpoint for \(endpoint.profileName)."
        }
    }

    private func delete(_ item: ObjectListItem) async {
        pendingDeletion = nil
        do {
            switch item {
            case .session(let session):
                try await profilesModel.deleteSession(named: session.id, mode: appModel.mode)
                if detailSelection == item.detailSelection {
                    detailSelection = nil
                }
            case .profile(let profile):
                imdsModel.stopEndpoint(forProfile: profile.id)
                try await profilesModel.deleteProfile(named: profile.id, mode: appModel.mode)
                if detailSelection == item.detailSelection {
                    detailSelection = nil
                }
            case .imds(let endpoint):
                if endpoint.isPersisted,
                   let definition = endpointDefinitions.first(where: { $0.stableIDString == endpoint.endpointID }) {
                    modelContext.delete(definition)
                    try modelContext.save()
                } else {
                    imdsModel.stopEndpoint(forProfile: endpoint.profileName)
                }
                if detailSelection == item.detailSelection {
                    detailSelection = nil
                }
            }
        } catch let err as AWSConfigINIError {
            actionError = err
            isPresentingActionError = true
        } catch {
            actionError = .malformedInput(error.localizedDescription)
            isPresentingActionError = true
        }
    }
}

private enum CreationSheet: Identifiable {
    case session
    case profile
    case imdsEndpoint

    var id: String {
        switch self {
        case .session: return "session"
        case .profile: return "profile"
        case .imdsEndpoint: return "imdsEndpoint"
        }
    }
}

private enum ObjectListItem: Identifiable, Hashable {
    case session(SSOSessionNode)
    case profile(SidebarProfileItem)
    case imds(TemporaryIMDSEndpointItem)

    var id: String {
        switch self {
        case .session(let session):
            return "session:\(session.id)"
        case .profile(let profile):
            return "profile:\(profile.id)"
        case .imds(let endpoint):
            return "imds:\(endpoint.id)"
        }
    }

    var detailSelection: DetailSelection {
        switch self {
        case .session(let session):
            return .session(name: session.id)
        case .profile(let profile):
            return .profile(name: profile.id)
        case .imds(let endpoint):
            return .imds(endpointID: endpoint.endpointID, profileName: endpoint.profileName)
        }
    }

    var searchText: String {
        switch self {
        case .session(let session):
            return "session \(session.id) \(session.session?.ssoStartUrl ?? "") \(session.session?.ssoRegion ?? "")"
        case .profile(let profile):
            return "profile \(profile.id) \(profile.via.label) \(profile.node.profile.ssoAccountId ?? "") \(profile.node.profile.ssoRoleName ?? "")"
        case .imds(let endpoint):
            return "imds endpoint \(endpoint.title) \(endpoint.profileName) \(endpoint.subtitle) \(endpoint.state.searchText)"
        }
    }

    var objectKind: MetadataObjectKind {
        switch self {
        case .session:
            return .session
        case .profile:
            return .profile
        case .imds:
            return .imdsEndpoint
        }
    }

    var objectID: String {
        switch self {
        case .session(let session):
            return session.id
        case .profile(let profile):
            return profile.id
        case .imds(let endpoint):
            return endpoint.id
        }
    }
}

private struct TemporaryIMDSEndpointItem: Identifiable, Hashable {
    let endpointID: String
    let name: String?
    let profileName: String
    let port: Int?
    let state: IMDSEndpointState
    let profile: ProfileNode?
    let isPersisted: Bool

    var id: String { endpointID }

    var title: String {
        if let name {
            return name
        }
        if let port = state.port ?? port {
            return "localhost:\(port)"
        }
        return profileName
    }

    var subtitle: String {
        if let port = state.port ?? port {
            return "localhost:\(port) -> \(profileName)"
        }
        return "serving \(profileName)"
    }
}

private struct ObjectListRow: View {
    let item: ObjectListItem

    var body: some View {
        switch item {
        case .session(let session):
            HStack(spacing: 8) {
                Image(systemName: "cloud")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.id)
                        .lineLimit(1)
                    Text("\(session.profiles.count) \(session.profiles.count == 1 ? "profile" : "profiles")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .padding(.vertical, 3)

        case .profile(let profile):
            HStack(spacing: 8) {
                Image(systemName: profile.via.isSSO ? "key" : "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 5) {
                    Text(profile.id)
                        .lineLimit(1)
                    ViaBadge(
                        label: profile.via.label,
                        color: profile.via.badgeColor
                    )
                }
                Spacer(minLength: 8)
            }
            .padding(.vertical, 3)

        case .imds(let endpoint):
            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(endpoint.state.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 5) {
                    Text(endpoint.title)
                        .fontDesign(.monospaced)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        IMDSBadge(state: endpoint.state)
                        Text(endpoint.profileName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.vertical, 3)
        }
    }
}

private struct IMDSBadge: View {
    let state: IMDSEndpointState

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(state.accent)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(state.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(state.accent.opacity(0.16), in: Capsule())
    }

    private var text: String {
        switch state {
        case .inactive:
            return "off"
        case .starting:
            return "starting"
        case .active:
            return "live"
        case .failed:
            return "failed"
        }
    }
}

private struct AddSessionSheet: View {
    let existingNames: Set<String>
    let onCreate: (String, SSOSession) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var startURL = ""
    @State private var region = ""
    @State private var scopes = "sso:account:access"
    @State private var validationMessage: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add SSO Session")
                .font(.title3.weight(.semibold))

            Form {
                TextField("Name", text: $name)
                TextField("Start URL", text: $startURL)
                TextField("Region", text: $region)
                TextField("Scopes", text: $scopes)
            }
            .formStyle(.grouped)

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") {
                    Task { await add() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func add() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationMessage = "Session name is required."
            return
        }
        guard !existingNames.contains(trimmedName) else {
            validationMessage = "A session named \(trimmedName) already exists."
            return
        }

        isSaving = true
        validationMessage = nil
        do {
            try await onCreate(
                trimmedName,
                SSOSession(
                    ssoStartUrl: nilIfBlank(startURL),
                    ssoRegion: nilIfBlank(region),
                    ssoRegistrationScopes: scopesList
                )
            )
            dismiss()
        } catch let error as LocalizedError {
            validationMessage = error.errorDescription ?? error.localizedDescription
        } catch {
            validationMessage = error.localizedDescription
        }
        isSaving = false
    }

    private var scopesList: [String]? {
        let values = scopes
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? nil : values
    }

    private func nilIfBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct AddProfileSheet: View {
    private static let noSessionTag = "__quorra_no_sso_session__"

    let existingNames: Set<String>
    let sessions: [SSOSessionNode]
    let onCreate: (String, Profile) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selectedSessionName: String
    @State private var region: String
    @State private var accountID = ""
    @State private var roleName = ""
    @State private var validationMessage: String?
    @State private var isSaving = false

    init(
        existingNames: Set<String>,
        sessions: [SSOSessionNode],
        defaultSessionName: String?,
        onCreate: @escaping (String, Profile) async throws -> Void
    ) {
        self.existingNames = existingNames
        self.sessions = sessions
        self.onCreate = onCreate

        let initialSessionName = defaultSessionName ?? Self.noSessionTag
        _selectedSessionName = State(initialValue: initialSessionName)
        _region = State(initialValue: sessions.first(where: { $0.id == initialSessionName })?.session?.ssoRegion ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add Profile")
                .font(.title3.weight(.semibold))

            Form {
                TextField("Name", text: $name)

                Picker("SSO Session", selection: $selectedSessionName) {
                    Text("None").tag(Self.noSessionTag)
                    ForEach(sessions) { session in
                        Text(session.id).tag(session.id)
                    }
                }

                if selectedSessionName != Self.noSessionTag {
                    TextField("Region", text: $region)
                    TextField("SSO Account ID", text: $accountID)
                    TextField("SSO Role Name", text: $roleName)
                }
            }
            .formStyle(.grouped)
            .onChange(of: selectedSessionName) { _, newValue in
                guard region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let sessionRegion = sessions.first(where: { $0.id == newValue })?.session?.ssoRegion else {
                    return
                }
                region = sessionRegion
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") {
                    Task { await add() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func add() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationMessage = "Profile name is required."
            return
        }
        guard !existingNames.contains(trimmedName) else {
            validationMessage = "A profile named \(trimmedName) already exists."
            return
        }

        isSaving = true
        validationMessage = nil
        do {
            try await onCreate(trimmedName, profile)
            dismiss()
        } catch let error as LocalizedError {
            validationMessage = error.errorDescription ?? error.localizedDescription
        } catch {
            validationMessage = error.localizedDescription
        }
        isSaving = false
    }

    private var profile: Profile {
        guard selectedSessionName != Self.noSessionTag else {
            return Profile()
        }
        return Profile(
            region: nilIfBlank(region),
            ssoSession: selectedSessionName,
            ssoAccountId: nilIfBlank(accountID),
            ssoRoleName: nilIfBlank(roleName)
        )
    }

    private func nilIfBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct AddIMDSEndpointSheet: View {
    let existingNames: Set<String>
    let usedPorts: Set<Int>
    let profiles: [ProfileNode]
    let onCreate: (IMDSEndpointDefinition) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var selectedProfileName: String
    @State private var bindAddress = "127.0.0.1"
    @State private var port: Int
    @State private var allowsIMDSv1 = true
    @State private var hopLimit = 2
    @State private var validationMessage: String?

    init(
        existingNames: Set<String>,
        usedPorts: Set<Int>,
        profiles: [ProfileNode],
        onCreate: @escaping (IMDSEndpointDefinition) throws -> Void
    ) {
        self.existingNames = existingNames
        self.usedPorts = usedPorts
        self.profiles = profiles
        self.onCreate = onCreate

        let firstProfileName = profiles.first?.id ?? ""
        _selectedProfileName = State(initialValue: firstProfileName)
        _name = State(initialValue: firstProfileName.isEmpty ? "" : firstProfileName)
        _port = State(initialValue: Self.firstAvailablePort(from: 9678, usedPorts: usedPorts))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add IMDS Endpoint")
                .font(.title3.weight(.semibold))

            Form {
                TextField("Name", text: $name)

                Picker("Profile", selection: $selectedProfileName) {
                    ForEach(profiles.sortedByName) { profile in
                        Text(profile.id).tag(profile.id)
                    }
                }

                TextField("Bind address", text: $bindAddress)
                    .fontDesign(.monospaced)

                TextField("Port", value: $port, format: .number)
                    .fontDesign(.monospaced)

                Toggle("Allow IMDSv1 fallback", isOn: $allowsIMDSv1)

                Stepper(value: $hopLimit, in: 1...64) {
                    Text("Hop limit \(hopLimit)")
                }
            }
            .formStyle(.grouped)
            .onChange(of: selectedProfileName) { _, newValue in
                guard name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                name = newValue
            }

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
        .frame(width: 460)
    }

    private func add() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBindAddress = bindAddress.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            validationMessage = "Endpoint name is required."
            return
        }
        guard !existingNames.contains(trimmedName) else {
            validationMessage = "An endpoint named \(trimmedName) already exists."
            return
        }
        guard !selectedProfileName.isEmpty else {
            validationMessage = "Select a profile to serve."
            return
        }
        guard !trimmedBindAddress.isEmpty else {
            validationMessage = "Bind address is required."
            return
        }
        guard (1...65_535).contains(port) else {
            validationMessage = "Port must be between 1 and 65535."
            return
        }
        guard !usedPorts.contains(port) else {
            validationMessage = "Port \(port) is already configured."
            return
        }

        do {
            try onCreate(IMDSEndpointDefinition(
                name: trimmedName,
                profileName: selectedProfileName,
                port: port,
                bindAddress: trimmedBindAddress,
                allowsIMDSv1: allowsIMDSv1,
                hopLimit: hopLimit
            ))
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private static func firstAvailablePort(from preferredPort: Int, usedPorts: Set<Int>) -> Int {
        var candidate = preferredPort
        while usedPorts.contains(candidate), candidate < 65_535 {
            candidate += 1
        }
        return candidate
    }
}

private extension [ProfileNode] {
    var sortedByName: [ProfileNode] {
        sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}

private extension SourceSelection {
    var emptySystemImage: String {
        switch self {
        case .all:
            return "square.grid.2x2"
        case .sessions:
            return "cloud"
        case .profiles:
            return "key"
        case .imdsEndpoints:
            return "antenna.radiowaves.left.and.right"
        case .folder(let kind, _, _):
            return kind.systemImage
        }
    }

    var emptyDescription: String {
        switch self {
        case .all:
            return "Create a session, profile, or IMDS endpoint to see it here."
        case .sessions:
            return "Create an SSO session to see it here."
        case .profiles:
            return "Create a profile to see it here."
        case .imdsEndpoints:
            return "Start or create an IMDS endpoint to see it here."
        case .folder:
            return "Assign items to this folder to see them here."
        }
    }
}

private extension ProfileVia {
    var badgeColor: Color? {
        switch self {
        case .session(let name):
            return Theme.sessionBadgeColor(for: name)
        case .longTerm, .other:
            return nil
        }
    }
}

private extension IMDSEndpointState {
    var isConcreteEndpoint: Bool {
        switch self {
        case .inactive:
            return false
        case .starting, .active, .failed:
            return true
        }
    }

    var accent: Color {
        switch self {
        case .inactive:
            return .secondary
        case .starting:
            return .blue
        case .active:
            return .green
        case .failed:
            return .orange
        }
    }

    var searchText: String {
        switch self {
        case .inactive:
            return "imds inactive"
        case .starting(let port):
            return "imds starting localhost 127.0.0.1 \(port)"
        case .active(let port):
            return "imds active live localhost 127.0.0.1 \(port)"
        case .failed(let port, let message):
            return "imds failed localhost 127.0.0.1 \(port) \(message)"
        }
    }
}

#Preview("Object List - all") {
    ObjectListPreviewHarness(sourceSelection: .all)
}

#Preview("Object List - profiles") {
    ObjectListPreviewHarness(
        sourceSelection: .profiles,
        detailSelection: .profile(name: "ac:cp:org_admin"),
        seedsActiveIMDS: true
    )
}

#Preview("Object List - searching") {
    ObjectListPreviewHarness(
        sourceSelection: .all,
        searchText: "ac:mgmt",
        seedsActiveIMDS: true
    )
}

private struct ObjectListPreviewHarness: View {
    @State private var sourceSelection: SourceSelection
    @State private var detailSelection: DetailSelection?
    @State private var searchText: String
    @State private var profilesModel: ProfilesModel
    @State private var imdsModel: IMDSModel

    init(
        sourceSelection: SourceSelection,
        detailSelection: DetailSelection? = nil,
        searchText: String = "",
        seedsActiveIMDS: Bool = false
    ) {
        let imdsModel = IMDSModel()
        if seedsActiveIMDS {
            imdsModel.setState(.active(port: 9678), forProfile: "ac:cp:org_admin")
        }

        _sourceSelection = State(initialValue: sourceSelection)
        _detailSelection = State(initialValue: detailSelection)
        _searchText = State(initialValue: searchText)
        _profilesModel = State(initialValue: ProfilesModel.previewLoaded(
            config: PreviewAWSFixtures.mockupConfig,
            credentials: PreviewAWSFixtures.mockupCredentials
        ))
        _imdsModel = State(initialValue: imdsModel)
    }

    var body: some View {
        NavigationSplitView {
            Text("Sources")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } content: {
            ObjectListView(
                sourceSelection: $sourceSelection,
                detailSelection: $detailSelection,
                searchText: $searchText
            )
        } detail: {
            Text("Detail")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(profilesModel)
        .environment(imdsModel)
        .environment(AppModel(initialPhase: .ready(URL(filePath: "/preview/.aws"))))
        .modelContainer(try! QuorraMetadataSchema.makeContainer(inMemory: true))
        .frame(width: 860, height: 560)
    }
}
