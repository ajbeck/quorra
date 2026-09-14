import SwiftUI
import IAMIdentityCenter
import QuorraAppLogic
import SwiftData

struct ProfileDetailView: View {
    let profile: ProfileDefinition
    @Binding var detailSelection: DetailSelection?
    @Binding var sourceSelection: SourceSelection
    @Binding var searchText: String
    @Environment(EditorState.self) private var editorState
    @Environment(CredentialsModel.self) private var credentialsModel
    @Environment(IMDSModel.self) private var imdsModel
    @Environment(\.modelContext) private var modelContext
    @Query private var endpointDefinitions: [IMDSEndpointDefinition]
    @State private var draft: ProfileDraft
    @State private var isEditing = false
    @State private var isPresentingEndpointEditor = false
    @State private var saveError: String?

    init(
        profile: ProfileDefinition,
        detailSelection: Binding<DetailSelection?>,
        sourceSelection: Binding<SourceSelection>,
        searchText: Binding<String>
    ) {
        self.profile = profile
        self._detailSelection = detailSelection
        self._sourceSelection = sourceSelection
        self._searchText = searchText
        self._draft = State(initialValue: ProfileDraft(profile))
    }

    private var stored: ProfileDraft { ProfileDraft(profile) }
    private var isDirty: Bool { draft != stored }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let coords = profile.credentialCoordinates { credentialsCard(coords) }
                identityCard
                sessionCard
            }
            .padding(32)
            .frame(maxWidth: 960, alignment: .leading)
        }
        .navigationTitle(profile.name)
        .navigationSubtitle(isDirty ? "Edited" : "")
        .sheet(isPresented: $isPresentingEndpointEditor) {
            IMDSEndpointEditorSheet(
                mode: .create,
                existingNames: Set(endpointDefinitions.map(\.name)),
                usedPorts: Set(endpointDefinitions.map(\.port)),
                profiles: (try? IdentityStore.eligibleProfiles(in: modelContext)) ?? [],
                initialDraft: endpointDraftForProfile()
            ) { draft in
                try createEndpoint(from: draft)
            }
        }
        .onChange(of: stored) { _, newValue in
            draft = newValue
            isEditing = false
        }
        .onChange(of: isDirty) { _, newValue in
            editorState.dirtyDescription = newValue ? "changes to profile \(profile.name)" : nil
        }
        .onDisappear {
            editorState.dirtyDescription = nil
        }
        .alert(
            "Couldn't save",
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(saveError ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(1)
                if isDirty {
                    Text("Unsaved changes")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 16)

            if isEditing {
                HStack(spacing: 8) {
                    Button("Discard", role: .destructive) {
                        draft = stored
                        isEditing = false
                    }

                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isDirty)
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Button {
                    isEditing = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
        }
    }

    private func credentialsCard(
        _ coords: (session: String, account: String, role: String, region: String, key: String)
    ) -> some View {
        DetailCard("Credentials") {
            CredentialsRevealSection(
                profileName: profile.name,
                sessionName: coords.session,
                accountId: coords.account,
                roleName: coords.role,
                region: coords.region,
                imdsEndpointCount: profile.endpoints.count,
                onSignIn: {
                    signIn()
                },
                onViewIMDS: {
                    if let endpoint = preferredProfileEndpoint {
                        navigateToEndpoint(endpoint)
                    }
                },
                onCreateIMDS: {
                    isPresentingEndpointEditor = true
                },
                onViewSession: {
                    detailSelection = .session(name: coords.session)
                }
            )
            .environment(credentialsModel)
        }
    }

    private var identityCard: some View {
        DetailCard("Identity") {
            DetailField("Region") {
                if !isEditing {
                    valueText(profile.region)
                } else {
                    TextField("us-east-1", text: $draft.region)
                        .fontDesign(.monospaced)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                }
            }
            DetailDivider()
            DetailField("Account ID") {
                if !isEditing {
                    valueText(profile.accountID)
                } else {
                    TextField("123456789012", text: $draft.accountID)
                        .fontDesign(.monospaced)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                }
            }
            DetailDivider()
            DetailField("Role Name") {
                if !isEditing {
                    valueText(profile.roleName)
                } else {
                    TextField("AdministratorAccess", text: $draft.roleName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                }
            }
        }
    }

    private var sessionCard: some View {
        DetailCard("Session") {
            DetailField("Session") {
                HStack(spacing: 8) {
                    valueText(profile.session?.name)
                    if let session = profile.session {
                        Button {
                            detailSelection = .session(name: session.name)
                        } label: {
                            Label("View", systemImage: "arrow.up.right.square")
                        }
                        .controlSize(.small)
                    }
                }
            }
            if profile.session == nil {
                Text("This profile is not linked to a session, so it cannot serve credentials. Delete it and add it again under a session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
    }

    private func valueText(_ value: String?) -> some View {
        let displayValue = displayValue(for: value)
        return Text(displayValue)
            .foregroundStyle(displayValue == "—" ? .secondary : .primary)
            .textSelection(.enabled)
    }

    private func displayValue(for value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        return value
    }

    private func save() {
        if let message = draft.validationMessage {
            saveError = message
            return
        }
        draft.apply(to: profile)
        do {
            try modelContext.save()
            isEditing = false
        } catch {
            modelContext.rollback()
            saveError = error.localizedDescription
        }
    }

    private func signIn() {
        guard let session = profile.session, let startURL = URL(string: session.startURL) else { return }
        let sessionName = session.name
        let region = session.region
        let scopes = session.registrationScopes
        Task {
            await credentialsModel.signIn(
                sessionName: sessionName,
                startUrl: startURL,
                region: region,
                scopes: scopes
            )
        }
    }

    /// Prefer the endpoint already serving this profile. When none is running, retain a
    /// deterministic single-click destination instead of making the user choose twice.
    private var preferredProfileEndpoint: IMDSEndpointDefinition? {
        profile.endpoints.sorted { lhs, rhs in
            let lhsRank = endpointNavigationRank(lhs)
            let rhsRank = endpointNavigationRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }.first
    }

    private func endpointNavigationRank(_ definition: IMDSEndpointDefinition) -> Int {
        switch imdsModel.state(forEndpointID: definition.stableIDString) {
        case .active: return 0
        case .starting: return 1
        case .inactive: return 2
        case .failed: return 3
        }
    }

    private func navigateToEndpoint(_ endpoint: IMDSEndpointDefinition) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            searchText = ""
            sourceSelection = .imdsEndpoints
            detailSelection = .imds(endpointID: endpoint.stableIDString)
        }
    }

    private func endpointDraftForProfile() -> IMDSEndpointEditorDraft {
        IMDSEndpointEditorDraft(
            name: profile.name,
            profileName: profile.name,
            profile: profile,
            port: firstAvailablePort(from: 9678),
            bindAddress: "127.0.0.1",
            allowsIMDSv1: true,
            hopLimit: 2
        )
    }

    private func createEndpoint(from draft: IMDSEndpointEditorDraft) throws {
        let endpoint = draft.makeEndpoint()
        modelContext.insert(endpoint)
        do {
            try modelContext.save()
        } catch {
            modelContext.delete(endpoint)
            throw error
        }
        sourceSelection = .imdsEndpoints
        searchText = profile.name
        detailSelection = .imds(endpointID: endpoint.stableIDString)
    }

    private func firstAvailablePort(from preferredPort: Int) -> Int {
        let usedPorts = Set(endpointDefinitions.map(\.port))
        var candidate = preferredPort
        while usedPorts.contains(candidate), candidate < 65_535 {
            candidate += 1
        }
        return candidate
    }
}

#if DEBUG

#Preview("Ready") {
    ProfileDetailPreviewHarness()
}

#Preview("Expired session") {
    ProfileDetailPreviewHarness(profileStatus: .signInExpired(sessionName: "astrocompute"))
}

#Preview("Profile not found") {
    ContentUnavailableView("Profile not found", systemImage: "questionmark.circle")
}

private struct ProfileDetailPreviewHarness: View {
    @State private var selection: DetailSelection? = .profile(name: "ac:cp:org_admin")
    @State private var sourceSelection: SourceSelection = .profiles
    @State private var searchText = ""
    @State private var editorState = EditorState()
    @State private var credentialsModel: CredentialsModel
    @State private var imdsModel = IMDSModel()
    private let metadataContainer = PreviewIdentityFixtures.makeContainer()
    private let profile: ProfileDefinition

    init(profileStatus: ProfileAuthStatus? = .ready(expiresAt: Date().addingTimeInterval(6 * 3600 + 12 * 60))) {
        let credentialsModel = CredentialsModel(service: PreviewIdentityCenterService())
        if let profileStatus {
            credentialsModel.seedProfileStatusForTesting(
                profileStatus,
                key: "astrocompute:699475923216:OrganizationAdmin"
            )
        }
        _credentialsModel = State(initialValue: credentialsModel)
        profile = try! IdentityStore.profile(named: "ac:cp:org_admin", in: metadataContainer.mainContext)!
    }

    var body: some View {
        ProfileDetailView(
            profile: profile,
            detailSelection: $selection,
            sourceSelection: $sourceSelection,
            searchText: $searchText
        )
            .environment(editorState)
            .environment(credentialsModel)
            .environment(imdsModel)
            .frame(width: 900, height: 720)
            .modelContainer(metadataContainer)
    }
}

#endif
