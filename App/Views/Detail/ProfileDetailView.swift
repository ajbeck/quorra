import SwiftUI
import AWSConfigINI
import IAMIdentityCenter

struct ProfileDetailView: View {
    let node: ProfileNode
    @Binding var detailSelection: DetailSelection?
    @Environment(AppModel.self) private var appModel
    @Environment(ProfilesModel.self) private var profilesModel
    @Environment(EditorState.self) private var editorState
    @Environment(CredentialsModel.self) private var credentialsModel
    @Environment(\.openSettings) private var openSettings
    @State private var draft: Profile
    @State private var isEditing = false
    @State private var isPresentingSaveError = false
    @State private var saveError: AWSConfigINIError?

    init(node: ProfileNode, detailSelection: Binding<DetailSelection?>) {
        self.node = node
        self._detailSelection = detailSelection
        self._draft = State(initialValue: node.profile)
    }

    private var isReadOnly: Bool { appModel.mode == .readOnly }
    private var isDirty: Bool { draft != node.profile }
    private var showsEditors: Bool { !isReadOnly && isEditing }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if isReadOnly { readOnlyNotice }
                if let coords = ssoCredentialCoordinates { credentialsCard(coords) }
                identityCard
                if draft.ssoSession != nil { sessionCard }
                if draft.roleArn != nil || draft.sourceProfile != nil { roleCard }
                if draft.credentialProcess != nil { credentialProcessCard }
            }
            .padding(32)
            .frame(maxWidth: 960, alignment: .leading)
        }
        .navigationTitle(node.id)
        .navigationSubtitle(isDirty ? "Edited" : "")
        .onChange(of: node) { _, newValue in
            draft = newValue.profile
            isEditing = false
        }
        .onChange(of: isDirty) { _, newValue in
            editorState.dirtyDescription = newValue ? "changes to profile \(node.id)" : nil
        }
        .onDisappear {
            editorState.dirtyDescription = nil
        }
        .alert(
            "Couldn't save",
            isPresented: $isPresentingSaveError,
            presenting: saveError
        ) { _ in
            Button("Retry") { Task { await save() } }
            Button("OK", role: .cancel) { }
        } message: { error in
            Text([error.errorDescription, error.recoverySuggestion]
                .compactMap { $0 }.joined(separator: "\n\n"))
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(node.id)
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
                        draft = node.profile
                        isEditing = false
                    }
                    .disabled(!isDirty)

                    Button("Save") {
                        Task { await save() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty)
                    .keyboardShortcut(.defaultAction)
                }
            } else if !isReadOnly {
                Button {
                    isEditing = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
        }
    }

    private var readOnlyNotice: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Read Only mode")
                    .font(.callout.weight(.semibold))
                Text("Quorra won't write to your AWS files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Open Settings…") { openSettings() }
                .controlSize(.small)
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// SSO-backed profiles expose the credentials reveal section (D31). Non-SSO profiles
    /// (static creds, role-assumption, credential_process) don't — `ProfileAuthStatus` /
    /// `liveCredentials` only apply to the SSO path.
    private var ssoCredentialCoordinates: (session: String, account: String, role: String, region: String)? {
        guard let session = draft.ssoSession,
              let account = draft.ssoAccountId,
              let role = draft.ssoRoleName else {
            return nil
        }
        // The Portal call is region-scoped. The profile's own region is the documented
        // input; absent that, default to us-east-1.
        return (session, account, role, draft.region ?? "us-east-1")
    }

    private func credentialsCard(
        _ coords: (session: String, account: String, role: String, region: String)
    ) -> some View {
        DetailCard("Credentials") {
            CredentialsRevealSection(
                profileName: node.id,
                sessionName: coords.session,
                accountId: coords.account,
                roleName: coords.role,
                region: coords.region,
                onSignIn: {
                    signIn(sessionName: coords.session)
                },
                onViewIMDS: {
                    detailSelection = .imds(endpointID: node.id, profileName: node.id)
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
                if !showsEditors {
                    valueText(draft.region)
                } else {
                    TextField("us-east-1", text: $draft.region.unwrapped())
                        .fontDesign(.monospaced)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                }
            }
            DetailDivider()
            DetailField("Output") {
                if !showsEditors {
                    valueText(draft.output)
                } else {
                    Picker("Output", selection: $draft.output.unwrapped()) {
                        Text("(default)").tag("")
                        Text("json").tag("json")
                        Text("text").tag("text")
                        Text("table").tag("table")
                        Text("yaml").tag("yaml")
                        Text("yaml-stream").tag("yaml-stream")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                }
            }
            DetailDivider()
            DetailField("SSO Account ID") {
                if !showsEditors {
                    valueText(draft.ssoAccountId)
                } else {
                    TextField("123456789012", text: $draft.ssoAccountId.unwrapped())
                        .fontDesign(.monospaced)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                }
            }
            DetailDivider()
            DetailField("SSO Role Name") {
                if !showsEditors {
                    valueText(draft.ssoRoleName)
                } else {
                    TextField("AdministratorAccess", text: $draft.ssoRoleName.unwrapped())
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                }
            }
        }
    }

    private var sessionCard: some View {
        DetailCard("SSO Session") {
            DetailField("Session") {
                HStack(spacing: 8) {
                    valueText(draft.ssoSession)
                    if let sessionName = draft.ssoSession {
                        Button {
                            detailSelection = .session(name: sessionName)
                        } label: {
                            Label("View", systemImage: "arrow.up.right.square")
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var roleCard: some View {
        DetailCard("Role") {
            editableTextField("Role ARN", value: $draft.roleArn, prompt: "arn:aws:iam::123456789012:role/MyRole")
            DetailDivider()
            editableTextField("Source Profile", value: $draft.sourceProfile, prompt: "default")
            DetailDivider()
            editableTextField("Role Session Name", value: $draft.roleSessionName, prompt: "my-session")
            DetailDivider()
            editableTextField("MFA Serial", value: $draft.mfaSerial, prompt: "arn:aws:iam::123456789012:mfa/user")
        }
    }

    private var credentialProcessCard: some View {
        DetailCard("Credential Process") {
            editableTextField("Command", value: $draft.credentialProcess, prompt: "/path/to/helper --profile name", monospaced: true)
        }
    }

    private func editableTextField(
        _ label: String,
        value: Binding<String?>,
        prompt: String,
        monospaced: Bool = false
    ) -> some View {
        DetailField(label) {
            if !showsEditors {
                valueText(value.wrappedValue)
            } else {
                TextField(prompt, text: value.unwrapped())
                    .fontDesign(monospaced ? .monospaced : .default)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 520)
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

    private func save() async {
        do {
            try await profilesModel.save(draft, for: node, mode: appModel.mode)
            isEditing = false
        } catch let err as AWSConfigINIError {
            saveError = err
            isPresentingSaveError = true
        } catch {
            saveError = .malformedInput(error.localizedDescription)
            isPresentingSaveError = true
        }
    }

    private func signIn(sessionName: String) {
        guard let session = profilesModel.findSession(named: sessionName),
              let startURLString = session.session?.ssoStartUrl,
              let startURL = URL(string: startURLString),
              let region = session.session?.ssoRegion else {
            detailSelection = .session(name: sessionName)
            return
        }

        let scopes = session.session?.ssoRegistrationScopes ?? ["sso:account:access"]
        Task {
            await credentialsModel.signIn(
                sessionName: sessionName,
                startUrl: startURL,
                region: region,
                scopes: scopes
            )
        }
    }
}

#Preview("Edit mode (clean)") {
    ProfileDetailPreviewHarness(mode: .managed)
}

#Preview("Read Only") {
    ProfileDetailPreviewHarness(mode: .readOnly)
}

#Preview("Expired session") {
    ProfileDetailPreviewHarness(
        mode: .managed,
        profileStatus: .signInExpired(sessionName: "astrocompute"),
        imdsState: nil
    )
}

#Preview("Profile not found") {
    ContentUnavailableView("Profile not found", systemImage: "questionmark.circle")
}

private struct ProfileDetailPreviewHarness: View {
    let mode: ManagedMode
    let imdsState: IMDSEndpointState?
    @State private var selection: DetailSelection? = .profile(name: "ac:cp:org_admin")
    @State private var appModel: AppModel
    @State private var profilesModel: ProfilesModel
    @State private var editorState = EditorState()
    @State private var credentialsModel: CredentialsModel
    @State private var imdsModel = IMDSModel()

    init(
        mode: ManagedMode,
        profileStatus: ProfileAuthStatus? = .ready(expiresAt: Date().addingTimeInterval(6 * 3600 + 12 * 60)),
        imdsState: IMDSEndpointState? = .active(port: 9678)
    ) {
        self.mode = mode
        self.imdsState = imdsState
        let folderURL = URL(filePath: "/preview/.aws", directoryHint: .isDirectory)
        let profilesModel = ProfilesModel.previewLoaded(
            config: PreviewAWSFixtures.mockupConfig,
            credentials: PreviewAWSFixtures.mockupCredentials,
            folder: folderURL
        )
        let credentialsModel = CredentialsModel(service: PreviewIdentityCenterService())
        if let profileStatus {
            credentialsModel.seedProfileStatusForTesting(
                profileStatus,
                key: "astrocompute:699475923216:OrganizationAdmin"
            )
        }

        _appModel = State(initialValue: AppModel(initialPhase: .ready(folderURL), initialMode: mode))
        _profilesModel = State(initialValue: profilesModel)
        _credentialsModel = State(initialValue: credentialsModel)
    }

    var body: some View {
        Group {
            if let node = profilesModel.findProfile(named: "ac:cp:org_admin") {
                ProfileDetailView(node: node, detailSelection: $selection)
                    .environment(appModel)
                    .environment(profilesModel)
                    .environment(editorState)
                    .environment(credentialsModel)
                    .environment(imdsModel)
            } else {
                ContentUnavailableView("Profile not found", systemImage: "questionmark.circle")
            }
        }
        .frame(width: 900, height: 720)
        .task {
            if let imdsState {
                imdsModel.setState(imdsState, forProfile: "ac:cp:org_admin")
            }
        }
    }
}
