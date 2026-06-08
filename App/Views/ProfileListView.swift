import SwiftUI
import AWSConfigINI
import IAMIdentityCenter

enum ProfileListMode: Hashable {
    case profiles
    case imds
}

struct ProfileListView: View {
    @Binding var sessionFilter: SessionFilter
    @Binding var selection: DetailSelection?
    @Environment(AppModel.self) private var appModel
    @Environment(ProfilesModel.self) private var profilesModel
    @Environment(IMDSModel.self) private var imdsModel

    @State private var mode: ProfileListMode
    @State private var searchText: String = ""
    @State private var isPresentingAddProfile = false
    @State private var isConfirmingDeleteProfile = false
    @State private var actionError: AWSConfigINIError?
    @State private var isPresentingActionError = false

    init(
        sessionFilter: Binding<SessionFilter>,
        selection: Binding<DetailSelection?>,
        initialMode: ProfileListMode = .profiles
    ) {
        self._sessionFilter = sessionFilter
        self._selection = selection
        self._mode = State(initialValue: initialMode)
    }

    var body: some View {
        switch profilesModel.loadState {
        case .idle, .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView(
                "Failed to Load Profiles",
                systemImage: "exclamationmark.triangle",
                description: Text("Quorra couldn't read your AWS configuration.")
            )
        case .loaded:
            loadedView
        }
    }

    private var loadedView: some View {
        VStack(spacing: 0) {
            TextField(searchPrompt, text: $searchText)
                .textFieldStyle(.roundedBorder)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Picker("View", selection: $mode) {
                Text("Profiles \(scopedProfileItems.count)").tag(ProfileListMode.profiles)
                Text("IMDS • \(activeIMDSCount)").tag(ProfileListMode.imds)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)

            if let sessionName = sessionFilter.sessionName {
                HStack {
                    FilterChip(title: "via \(sessionName)") {
                        sessionFilter = .all
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
            }

            profileListContainer
        }
        .onChange(of: sessionFilter) { _, _ in
            clearSelectionIfNeeded()
        }
        .onChange(of: mode) { oldMode, newMode in
            convertSelection(from: oldMode, to: newMode)
        }
        .onChange(of: profilesModel.loadState) { _, _ in
            clearSelectionIfNeeded()
        }
        .sheet(isPresented: $isPresentingAddProfile) {
            AddProfileSheet(
                existingNames: Set(profilesModel.groups.flatProfiles.map(\.id)),
                sessions: profilesModel.groups.ssoSessions,
                defaultSessionName: sessionFilter.sessionName
            ) { name, profile in
                try await profilesModel.createProfile(named: name, profile: profile, mode: appModel.mode)
                searchText = ""
                selection = .profile(name: name)
            }
        }
        .confirmationDialog(
            "Delete profile?",
            isPresented: $isConfirmingDeleteProfile,
            titleVisibility: .visible
        ) {
            if let selectedProfileName {
                Button("Delete \(selectedProfileName)", role: .destructive) {
                    Task { await deleteProfile(named: selectedProfileName) }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            if let selectedProfileName {
                Text("This removes \(selectedProfileName) from your AWS config and credentials files. Any running IMDS endpoint for this profile will be stopped.")
            }
        }
        .alert(
            "Couldn't update profiles",
            isPresented: $isPresentingActionError,
            presenting: actionError
        ) { _ in
            Button("OK", role: .cancel) { }
        } message: { error in
            Text([error.errorDescription, error.recoverySuggestion]
                .compactMap { $0 }.joined(separator: "\n\n"))
        }
    }

    private var profileListContainer: some View {
        VStack(spacing: 0) {
            listContent
                .frame(maxHeight: .infinity)

            Divider()
            profileMutationBar
        }
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.10))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity)
    }

    private var profileMutationBar: some View {
        HStack(spacing: 0) {
            profileActions
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Color.secondary.opacity(0.10))
    }

    private var profileActions: some View {
        ControlGroup {
            Button {
                isPresentingAddProfile = true
            } label: {
                Label("Add Profile", systemImage: "plus")
            }
            .disabled(isReadOnly || mode != .profiles)
            .help(addProfileHelp)

            Button {
                isConfirmingDeleteProfile = true
            } label: {
                Label("Remove Profile", systemImage: "minus")
            }
            .disabled(isReadOnly || mode != .profiles || selectedProfileName == nil)
            .help(removeProfileHelp)
        }
        .controlSize(.small)
        .labelStyle(.iconOnly)
    }

    @ViewBuilder private var listContent: some View {
        switch mode {
        case .profiles:
            profileList
        case .imds:
            imdsList
        }
    }

    private var profileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(filteredProfileItems) { item in
                    detailButton(for: .profile(name: item.id)) {
                        ProfileListRow(
                            item: item,
                            imdsState: imdsModel.state(forProfile: item.id)
                        )
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .overlay { emptyProfilesOverlay }
    }

    private var imdsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(filteredIMDSItems) { item in
                    detailButton(for: .imds(profileName: item.id)) {
                        IMDSListRow(
                            item: item,
                            state: imdsModel.state(forProfile: item.id)
                        )
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .overlay { emptyIMDSOverlay }
    }

    private func detailButton<Label: View>(
        for candidate: DetailSelection,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button {
            selection = candidate
        } label: {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(rowBackground(isSelected: selection == candidate), in: RoundedRectangle(cornerRadius: 6))
    }

    private func rowBackground(isSelected: Bool) -> Color {
        isSelected ? Color.accentColor.opacity(0.18) : Color.clear
    }

    @ViewBuilder private var emptyProfilesOverlay: some View {
        if filteredProfileItems.isEmpty {
            if searchText.isEmpty {
                ContentUnavailableView("No Profiles", systemImage: "person.crop.circle.badge.questionmark")
            } else {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    @ViewBuilder private var emptyIMDSOverlay: some View {
        if filteredIMDSItems.isEmpty {
            if searchText.isEmpty {
                ContentUnavailableView("No IMDS Endpoints", systemImage: "antenna.radiowaves.left.and.right")
            } else {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private var scopedProfileItems: [SidebarProfileItem] {
        switch sessionFilter {
        case .all:
            return profilesModel.groups.flatProfiles
        case .session(let name):
            guard let session = profilesModel.findSession(named: name) else { return [] }
            return session.profiles
                .map { SidebarProfileItem(node: $0, via: .session(name)) }
                .sorted(by: profileItemSortOrder)
        }
    }

    private var filteredProfileItems: [SidebarProfileItem] {
        guard !searchText.isEmpty else { return scopedProfileItems }
        return scopedProfileItems.filter { item in
            item.id.localizedCaseInsensitiveContains(searchText)
                || item.via.label.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var scopedIMDSItems: [SidebarProfileItem] {
        scopedProfileItems.filter { $0.via.isSSO }
    }

    private var filteredIMDSItems: [SidebarProfileItem] {
        guard !searchText.isEmpty else { return scopedIMDSItems }
        return scopedIMDSItems.filter { item in
            let state = imdsModel.state(forProfile: item.id)
            return item.id.localizedCaseInsensitiveContains(searchText)
                || item.via.label.localizedCaseInsensitiveContains(searchText)
                || state.searchText.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var activeIMDSCount: Int {
        scopedIMDSItems.filter { imdsModel.state(forProfile: $0.id).isActive }.count
    }

    private var selectedProfileName: String? {
        guard case .profile(let name) = selection,
              scopedProfileItems.contains(where: { $0.id == name }) else {
            return nil
        }
        return name
    }

    private var isReadOnly: Bool {
        appModel.mode == .readOnly
    }

    private var searchPrompt: String {
        mode == .imds ? "Filter servers" : "Filter profiles"
    }

    private var addProfileHelp: String {
        if isReadOnly { return "Switch to Edit & Manage mode to add profiles." }
        if mode != .profiles { return "Switch to Profiles to add a profile." }
        return "Add profile"
    }

    private var removeProfileHelp: String {
        if isReadOnly { return "Switch to Edit & Manage mode to remove profiles." }
        if mode != .profiles { return "Switch to Profiles to remove a profile." }
        if selectedProfileName == nil { return "Select a profile to remove." }
        return "Remove selected profile"
    }

    private func profileItemSortOrder(_ a: SidebarProfileItem, _ b: SidebarProfileItem) -> Bool {
        let aDefault = a.id == "default"
        let bDefault = b.id == "default"
        if aDefault != bDefault { return aDefault }
        return a.id.localizedStandardCompare(b.id) == .orderedAscending
    }

    private func clearSelectionIfNeeded() {
        guard let selection else { return }
        switch selection {
        case .profile(let name):
            if !scopedProfileItems.contains(where: { $0.id == name }) {
                self.selection = nil
            }
        case .imds(let profileName):
            if !scopedIMDSItems.contains(where: { $0.id == profileName }) {
                self.selection = nil
            }
        case .session:
            break
        }
    }

    private func convertSelection(from oldMode: ProfileListMode, to newMode: ProfileListMode) {
        guard oldMode != newMode, let selection else { return }
        switch (newMode, selection) {
        case (.imds, .profile(let name)):
            self.selection = scopedIMDSItems.contains(where: { $0.id == name })
                ? .imds(profileName: name)
                : nil
        case (.profiles, .imds(let profileName)):
            self.selection = scopedProfileItems.contains(where: { $0.id == profileName })
                ? .profile(name: profileName)
                : nil
        default:
            break
        }
    }

    private func deleteProfile(named name: String) async {
        do {
            imdsModel.stopEndpoint(forProfile: name)
            try await profilesModel.deleteProfile(named: name, mode: appModel.mode)
            if selection == .profile(name: name) || selection == .imds(profileName: name) {
                selection = scopedProfileItems.first.map { .profile(name: $0.id) }
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

private struct ProfileListRow: View {
    let item: SidebarProfileItem
    let imdsState: IMDSEndpointState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.id)
                .lineLimit(1)

            rowBadge
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var rowBadge: some View {
        if item.via.isSSO {
            IMDSBadge(state: imdsState)
        } else {
            ViaBadge(label: item.via.label)
        }
    }
}

private struct IMDSListRow: View {
    let item: SidebarProfileItem
    let state: IMDSEndpointState

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.id)
                    .lineLimit(1)
                IMDSBadge(state: state)
            }

            Spacer(minLength: 8)

            if let port = state.port {
                Text("127.0.0.1:\(port)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct IMDSBadge: View {
    let state: IMDSEndpointState

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(textColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(backgroundColor, in: Capsule())
    }

    private var text: String {
        switch state {
        case .inactive:
            return "IMDS"
        case .starting(let port):
            return "IMDS : \(port)"
        case .active(let port):
            return "IMDS : \(port)"
        case .failed(let port, _):
            return "IMDS : \(port)"
        }
    }

    private var dotColor: Color {
        switch state {
        case .inactive: return .secondary.opacity(0.55)
        case .starting: return .blue
        case .active: return .green
        case .failed: return .orange
        }
    }

    private var textColor: Color {
        switch state {
        case .inactive: return .secondary
        case .starting: return .blue
        case .active: return .green
        case .failed: return .orange
        }
    }

    private var backgroundColor: Color {
        switch state {
        case .inactive: return Color.secondary.opacity(0.12)
        case .starting: return Color.blue.opacity(0.16)
        case .active: return Color.green.opacity(0.18)
        case .failed: return Color.orange.opacity(0.16)
        }
    }
}

private struct FilterChip: View {
    let title: String
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .help("Clear filter")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.15), in: Capsule())
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

private extension IMDSEndpointState {
    var searchText: String {
        switch self {
        case .inactive:
            return "imds inactive"
        case .starting(let port):
            return "imds starting 127.0.0.1 \(port)"
        case .active(let port):
            return "imds active 127.0.0.1 \(port)"
        case .failed(let port, let message):
            return "imds failed 127.0.0.1 \(port) \(message)"
        }
    }
}

#Preview("ProfileList – all") {
    ProfileListPreviewHarness(sessionFilter: .all)
}

#Preview("ProfileList – filtered") {
    ProfileListPreviewHarness(
        sessionFilter: .session(name: "astrocompute"),
        selection: .profile(name: "ac:cp:org_admin"),
        seedsActiveIMDS: true
    )
}

#Preview("ProfileList – IMDS") {
    ProfileListPreviewHarness(
        sessionFilter: .session(name: "astrocompute"),
        selection: .imds(profileName: "ac:cp:org_admin"),
        initialMode: .imds,
        seedsActiveIMDS: true
    )
}

private struct ProfileListPreviewHarness: View {
    @State private var sessionFilter: SessionFilter
    @State private var selection: DetailSelection?
    @State private var profilesModel: ProfilesModel
    @State private var imdsModel: IMDSModel
    private let initialMode: ProfileListMode

    init(
        sessionFilter: SessionFilter,
        selection: DetailSelection? = nil,
        initialMode: ProfileListMode = .profiles,
        seedsActiveIMDS: Bool = false
    ) {
        let imdsModel = IMDSModel()
        if seedsActiveIMDS {
            imdsModel.setState(.active(port: 9678), forProfile: "ac:cp:org_admin")
        }

        _sessionFilter = State(initialValue: sessionFilter)
        _selection = State(initialValue: selection)
        _profilesModel = State(initialValue: ProfilesModel.previewLoaded(
            config: PreviewAWSFixtures.mockupConfig,
            credentials: PreviewAWSFixtures.mockupCredentials
        ))
        _imdsModel = State(initialValue: imdsModel)
        self.initialMode = initialMode
    }

    var body: some View {
        NavigationSplitView {
            Text("Sessions")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } content: {
            ProfileListView(
                sessionFilter: $sessionFilter,
                selection: $selection,
                initialMode: initialMode
            )
        } detail: {
            Text("Detail")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(profilesModel)
        .environment(imdsModel)
        .environment(AppModel(initialPhase: .ready(URL(filePath: "/preview/.aws"))))
        .frame(width: 860, height: 560)
    }
}
