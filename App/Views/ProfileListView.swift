import SwiftUI
import QuorraAppLogic
import SwiftData

struct ObjectListView: View {
    @Binding var sourceSelection: SourceSelection
    @Binding var detailSelection: DetailSelection?
    @Binding var searchText: String
    @Environment(IMDSModel.self) private var imdsModel
    @Environment(CredentialsModel.self) private var credentialsModel
    @Environment(\.modelContext) private var modelContext
    @Query private var sessionDefinitions: [SessionDefinition]
    @Query private var profileDefinitions: [ProfileDefinition]
    @Query private var endpointDefinitions: [IMDSEndpointDefinition]

    @State private var presentedSheet: CreationSheet?
    @State private var pendingDeletion: ObjectListItem?
    @State private var deletionError: String?
    @FocusState private var isListFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            listContent
                .frame(maxHeight: .infinity)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    objectMutationBar
                }
        }
        .task(id: profileDefinitions.compactMap { $0.credentialCoordinates?.key }) {
            // Observe every profile's status once, so the first frame of a profile's detail
            // already knows it is ready instead of drawing "Checking" and then redrawing
            // (post-1.0 D3). Both calls return at once for entries already cached, and the
            // event stream keeps the entries fresh (D30).
            for profile in profileDefinitions {
                guard let coordinates = profile.credentialCoordinates else { continue }
                await credentialsModel.observeStatus(forSession: coordinates.session)
                await credentialsModel.observeProfileStatus(
                    forSession: coordinates.session,
                    accountId: coordinates.account,
                    roleName: coordinates.role
                )
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .session:
                AddSessionSheet(existingNames: Set(sessionDefinitions.map(\.name))) { session in
                    try insertAndSave(session)
                    select(.sessions, .session(name: session.name))
                }
            case .profile:
                AddProfileSheet(
                    existingNames: Set(profileDefinitions.map(\.name)),
                    sessions: sortedSessions
                ) { profile in
                    try insertAndSave(profile)
                    select(.profiles, .profile(name: profile.name))
                }
            case .imdsEndpoint:
                IMDSEndpointEditorSheet(
                    mode: .create,
                    existingNames: Set(endpointDefinitions.map(\.name)),
                    usedPorts: Set(endpointDefinitions.map(\.port)),
                    profiles: eligibleProfiles
                ) { draft in
                    let endpoint = draft.makeEndpoint()
                    try insertAndSave(endpoint)
                    select(.imdsEndpoints, .imds(endpointID: endpoint.stableIDString))
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
                    delete(pendingDeletion)
                }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            if let pendingDeletion {
                Text(deletionMessage(for: pendingDeletion))
            }
        }
        .alert(
            "Couldn't delete",
            isPresented: Binding(
                get: { deletionError != nil },
                set: { if !$0 { deletionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(deletionError ?? "")
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

    @ViewBuilder private var listContent: some View {
        if visibleItems.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                List(selection: $detailSelection) {
                    if case .all = sourceSelection {
                        if !filteredSessionItems.isEmpty {
                            Section("Sessions") {
                                ForEach(filteredSessionItems, id: \.detailSelection) { item in
                                    ObjectListRow(item: item)
                                        .tag(item.detailSelection)
                                }
                            }
                        }
                        if !filteredProfileItems.isEmpty {
                            Section("Profiles") {
                                ForEach(filteredProfileItems, id: \.detailSelection) { item in
                                    ObjectListRow(item: item)
                                        .tag(item.detailSelection)
                                }
                            }
                        }
                        if !filteredIMDSItems.isEmpty {
                            Section("IMDS Endpoints") {
                                ForEach(filteredIMDSItems, id: \.detailSelection) { item in
                                    ObjectListRow(item: item)
                                        .tag(item.detailSelection)
                                }
                            }
                        }
                    } else {
                        ForEach(visibleItems, id: \.detailSelection) { item in
                            ObjectListRow(item: item)
                                .tag(item.detailSelection)
                        }
                    }
                }
                .focusable()
                .focused($isListFocused)
                .focusEffectDisabled()
                .simultaneousGesture(TapGesture().onEnded { isListFocused = true })
                .onMoveCommand { direction in
                    guard let next = adjacentSelection(direction) else { return }
                    detailSelection = next
                    proxy.scrollTo(next)
                }
            }
        }
    }

    /// The row the arrow keys move to, in the order the list shows its rows.
    private func adjacentSelection(_ direction: MoveCommandDirection) -> DetailSelection? {
        let rows = visibleItems.map(\.detailSelection)
        guard let current = detailSelection, let index = rows.firstIndex(of: current) else {
            return direction == .up ? rows.last : rows.first
        }
        switch direction {
        case .up:
            return rows[max(index - 1, 0)]
        case .down:
            return rows[min(index + 1, rows.count - 1)]
        default:
            return nil
        }
    }

    private var objectMutationBar: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 0) {
                if let defaultCreationSheet {
                    Button {
                        presentedSheet = defaultCreationSheet
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 18, height: 18)
                    }
                    .frame(width: 26, height: 26)
                    .contentShape(.rect)
                    .disabled(isCreationDisabled(defaultCreationSheet))
                    .help(creationHelp(for: defaultCreationSheet))
                } else {
                    Menu {
                        creationMenu
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 18, height: 18)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 26, height: 26)
                    .contentShape(.rect)
                    .help("Add session, profile, or IMDS endpoint")
                }

                Rectangle()
                    .fill(Color.secondary.opacity(0.16))
                    .frame(width: 1, height: 14)

                Button {
                    if let selectedItem {
                        pendingDeletion = selectedItem
                    }
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 18, height: 18)
                }
                .frame(width: 26, height: 26)
                .contentShape(.rect)
                .disabled(!canDeleteSelectedItem)
                .help(removeHelp)

                Spacer(minLength: 0)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 8)
            .frame(height: 26)
        }
        .background(.bar)
    }

    @ViewBuilder private var creationMenu: some View {
        Button {
            presentedSheet = .session
        } label: {
            Label("New Session", systemImage: "cloud")
        }

        Button {
            presentedSheet = .profile
        } label: {
            Label("New Profile", systemImage: "key")
        }
        .disabled(isCreationDisabled(.profile))

        Button {
            presentedSheet = .imdsEndpoint
        } label: {
            Label("New IMDS Endpoint", systemImage: "antenna.radiowaves.left.and.right")
        }
        .disabled(isCreationDisabled(.imdsEndpoint))
    }

    private var defaultCreationSheet: CreationSheet? {
        switch sourceSelection {
        case .all:
            nil
        case .sessions:
            .session
        case .profiles:
            .profile
        case .imdsEndpoints:
            .imdsEndpoint
        }
    }

    private func isCreationDisabled(_ sheet: CreationSheet) -> Bool {
        switch sheet {
        case .session:
            false
        case .profile:
            sessionDefinitions.isEmpty
        case .imdsEndpoint:
            eligibleProfiles.isEmpty
        }
    }

    private func creationHelp(for sheet: CreationSheet) -> String {
        switch sheet {
        case .session:
            return "New Session"
        case .profile:
            return sessionDefinitions.isEmpty ? "Add a session before adding profiles." : "New Profile"
        case .imdsEndpoint:
            return eligibleProfiles.isEmpty ? "Add a profile before adding IMDS endpoints." : "New IMDS Endpoint"
        }
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

    private var sortedSessions: [SessionDefinition] {
        sessionDefinitions.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// `default` first, then by name, matching the AWS CLI's own ordering.
    private var sortedProfiles: [ProfileDefinition] {
        profileDefinitions.sorted { lhs, rhs in
            let lhsDefault = lhs.name == "default"
            let rhsDefault = rhs.name == "default"
            if lhsDefault != rhsDefault { return lhsDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var eligibleProfiles: [ProfileDefinition] {
        sortedProfiles.filter { $0.session != nil }
    }

    private var sessionItems: [ObjectListItem] {
        sortedSessions.map {
            .session(SessionListItem(name: $0.name, startURL: $0.startURL, region: $0.region, profileCount: $0.profiles.count))
        }
    }

    private var profileItems: [ObjectListItem] {
        sortedProfiles.map {
            .profile(ProfileListItem(name: $0.name, sessionName: $0.session?.name, accountID: $0.accountID, roleName: $0.roleName))
        }
    }

    private var imdsItems: [ObjectListItem] {
        endpointDefinitions.map { definition in
            IMDSEndpointListItem(
                endpointID: definition.stableIDString,
                name: definition.name,
                profileName: definition.profile?.name ?? "",
                port: definition.port,
                state: imdsModel.state(forEndpointID: definition.stableIDString)
            )
        }
            .sorted {
                if $0.isDefault != $1.isDefault {
                    return $0.isDefault
                }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            .map { .imds($0) }
    }

    private var filteredSessionItems: [ObjectListItem] {
        filtered(sessionItems)
    }

    private var filteredProfileItems: [ObjectListItem] {
        filtered(profileItems)
    }

    private var filteredIMDSItems: [ObjectListItem] {
        filtered(imdsItems)
    }

    private var sourceItems: [ObjectListItem] {
        switch sourceSelection {
        case .all:
            return sessionItems + profileItems + imdsItems
        case .sessions:
            return sessionItems
        case .profiles:
            return profileItems
        case .imdsEndpoints:
            return imdsItems
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

    private var canDeleteSelectedItem: Bool {
        guard let selectedItem else { return false }
        switch selectedItem {
        case .session, .profile:
            return true
        case .imds(let endpoint):
            return !endpoint.isDefault
        }
    }

    private var removeHelp: String {
        guard let selectedItem else { return "Select an item to remove." }
        switch selectedItem {
        case .session:
            return "Delete selected session"
        case .profile:
            return "Delete selected profile"
        case .imds(let endpoint):
            return endpoint.isDefault
                ? "The Default IMDS Endpoint is always available."
                : "Remove selected IMDS endpoint"
        }
    }

    private var deletionTitle: String {
        guard let pendingDeletion else { return "Remove item?" }
        switch pendingDeletion {
        case .session:
            return "Delete session?"
        case .profile:
            return "Delete profile?"
        case .imds:
            return "Remove IMDS endpoint?"
        }
    }

    private func deletionButtonTitle(for item: ObjectListItem) -> String {
        switch item {
        case .session(let session):
            return "Delete \(session.name)"
        case .profile(let profile):
            return "Delete \(profile.name)"
        case .imds(let endpoint):
            return "Remove \(endpoint.title)"
        }
    }

    private func deletionMessage(for item: ObjectListItem) -> String {
        switch item {
        case .session(let session):
            let profiles = "\(session.profileCount) \(session.profileCount == 1 ? "profile" : "profiles")"
            return "This deletes \(session.name) and its \(profiles) from Quorra. IMDS endpoints serving those profiles are stopped and left without a profile."
        case .profile(let profile):
            return "This deletes \(profile.name) from Quorra. Any IMDS endpoint serving it is stopped and left without a profile."
        case .imds(let endpoint):
            return "This removes the \(endpoint.title) IMDS endpoint and its activity log from Quorra."
        }
    }

    private func select(_ source: SourceSelection, _ detail: DetailSelection) {
        searchText = ""
        sourceSelection = source
        detailSelection = detail
    }

    private func insertAndSave(_ model: some PersistentModel) throws {
        modelContext.insert(model)
        do {
            try modelContext.save()
        } catch {
            modelContext.delete(model)
            throw error
        }
    }

    private func delete(_ item: ObjectListItem) {
        pendingDeletion = nil
        do {
            switch item {
            case .session(let session):
                guard let definition = sessionDefinitions.first(where: { $0.name == session.name }) else { return }
                for profile in definition.profiles {
                    stopEndpoints(serving: profile)
                }
                modelContext.delete(definition)
                try modelContext.save()
            case .profile(let profile):
                guard let definition = profileDefinitions.first(where: { $0.name == profile.name }) else { return }
                stopEndpoints(serving: definition)
                modelContext.delete(definition)
                try modelContext.save()
            case .imds(let endpoint):
                guard let definition = endpointDefinitions.first(where: { $0.stableIDString == endpoint.endpointID }) else { return }
                imdsModel.stopEndpoint(forEndpointID: definition.stableIDString)
                try IMDSEndpointLogStore.deleteAll(endpointID: definition.stableID, in: modelContext)
                modelContext.delete(definition)
                try modelContext.save()
            }
            if detailSelection == item.detailSelection {
                detailSelection = nil
            }
        } catch {
            modelContext.rollback()
            deletionError = error.localizedDescription
        }
    }

    private func stopEndpoints(serving profile: ProfileDefinition) {
        for endpoint in profile.endpoints {
            imdsModel.stopEndpoint(forEndpointID: endpoint.stableIDString)
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
        }
    }

    var emptyDescription: String {
        switch self {
        case .all:
            return "Add a session, profile, or IMDS endpoint to see it here."
        case .sessions:
            return "Add an IAM Identity Center session to see it here."
        case .profiles:
            return "Sign in to a session, then add a profile for one of its accounts."
        case .imdsEndpoints:
            return "Add an IMDS endpoint to see it here."
        }
    }
}

#if DEBUG

#Preview("Object List - all") {
    ObjectListPreviewHarness(sourceSelection: .all)
}

#Preview("Object List - profiles") {
    ObjectListPreviewHarness(
        sourceSelection: .profiles,
        detailSelection: .profile(name: "ac:cp:org_admin")
    )
}

#Preview("Object List - searching") {
    ObjectListPreviewHarness(
        sourceSelection: .all,
        searchText: "ac:mgmt",
        seedsEndpointDefinition: true
    )
}

private struct ObjectListPreviewHarness: View {
    @State private var sourceSelection: SourceSelection
    @State private var detailSelection: DetailSelection?
    @State private var searchText: String
    @State private var imdsModel: IMDSModel
    private let metadataContainer: ModelContainer

    init(
        sourceSelection: SourceSelection,
        detailSelection: DetailSelection? = nil,
        searchText: String = "",
        seedsEndpointDefinition: Bool = false
    ) {
        let imdsModel = IMDSModel()
        if seedsEndpointDefinition {
            imdsModel.setState(.active(port: 9678), forEndpointID: PreviewIdentityFixtures.endpointID.uuidString)
        }

        _sourceSelection = State(initialValue: sourceSelection)
        _detailSelection = State(initialValue: detailSelection)
        _searchText = State(initialValue: searchText)
        _imdsModel = State(initialValue: imdsModel)
        metadataContainer = PreviewIdentityFixtures.makeContainer(seedsEndpoint: seedsEndpointDefinition)
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
        .environment(imdsModel)
        .environment(CredentialsModel(service: PreviewIdentityCenterService()))
        .modelContainer(metadataContainer)
        .frame(width: 860, height: 560)
    }
}

#endif
