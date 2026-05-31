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
    @Environment(ProfilesModel.self) private var profilesModel
    @Environment(IMDSModel.self) private var imdsModel

    @State private var mode: ProfileListMode
    @State private var searchText: String = ""

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
        VStack(spacing: 8) {
            TextField("Filter profiles", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.top, 12)

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

            listContent
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
        .frame(width: 860, height: 560)
    }
}
