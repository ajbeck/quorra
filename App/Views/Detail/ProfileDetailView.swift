import SwiftUI
import AWSConfigINI

struct ProfileDetailView: View {
    let node: ProfileNode
    @Binding var sidebarSelection: SidebarSelection?
    @Environment(AppModel.self) private var appModel
    @Environment(ProfilesModel.self) private var profilesModel
    @Environment(EditorState.self) private var editorState
    @Environment(\.openSettings) private var openSettings
    @State private var draft: Profile
    @State private var isPresentingSaveError = false
    @State private var saveError: AWSConfigINIError?

    init(node: ProfileNode, sidebarSelection: Binding<SidebarSelection?>) {
        self.node = node
        self._sidebarSelection = sidebarSelection
        self._draft = State(initialValue: node.profile)
    }

    private var isReadOnly: Bool { appModel.mode == .readOnly }
    private var isDirty: Bool { draft != node.profile }

    var body: some View {
        Form {
            if isReadOnly { readOnlyBanner }
            identitySection
            if draft.ssoSession != nil { sessionLinkSection }
            if draft.roleArn != nil || draft.sourceProfile != nil { roleSection }
            if draft.credentialProcess != nil { credentialProcessSection }
        }
        .formStyle(.grouped)
        .navigationTitle(node.id)
        .navigationSubtitle(isDirty ? "Edited" : "")
        .toolbar { editorToolbar }
        .onChange(of: node) { _, newValue in
            draft = newValue.profile
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

    @ToolbarContentBuilder private var editorToolbar: some ToolbarContent {
        if !isReadOnly {
            ToolbarItem(placement: .cancellationAction) {
                Button("Discard", role: .destructive) {
                    draft = node.profile
                }
                .disabled(!isDirty)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await save() }
                }
                .disabled(!isDirty)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func save() async {
        do {
            try await profilesModel.save(draft, for: node)
        } catch let err as AWSConfigINIError {
            saveError = err
            isPresentingSaveError = true
        } catch {
            saveError = .malformedInput(error.localizedDescription)
            isPresentingSaveError = true
        }
    }

    @ViewBuilder private var readOnlyBanner: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Read Only mode").font(.callout.weight(.semibold))
                    Text("Quorra won't write to your AWS files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Open Settings…") { openSettings() }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder private var identitySection: some View {
        Section("Identity") {
            if isReadOnly {
                LabeledContent("Region", value: draft.region ?? "—")
                LabeledContent("Output", value: draft.output ?? "—")
                LabeledContent("SSO Account ID", value: draft.ssoAccountId ?? "—")
                LabeledContent("SSO Role Name", value: draft.ssoRoleName ?? "—")
            } else {
                TextField("Region", text: $draft.region.unwrapped(), prompt: Text("us-east-1"))
                    .fontDesign(.monospaced)
                Picker("Output", selection: $draft.output.unwrapped()) {
                    Text("(default)").tag("")
                    Text("json").tag("json")
                    Text("text").tag("text")
                    Text("table").tag("table")
                    Text("yaml").tag("yaml")
                    Text("yaml-stream").tag("yaml-stream")
                }
                TextField("SSO Account ID", text: $draft.ssoAccountId.unwrapped(), prompt: Text("123456789012"))
                TextField("SSO Role Name", text: $draft.ssoRoleName.unwrapped(), prompt: Text("AdministratorAccess"))
            }
        }
    }

    @ViewBuilder private var sessionLinkSection: some View {
        Section("SSO Session") {
            LabeledContent("Session", value: draft.ssoSession ?? "—")
            if let sessionName = draft.ssoSession {
                Button("View session…") {
                    sidebarSelection = .session(name: sessionName)
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder private var roleSection: some View {
        Section("Role") {
            if isReadOnly {
                LabeledContent("Role ARN", value: draft.roleArn ?? "—")
                LabeledContent("Source Profile", value: draft.sourceProfile ?? "—")
                LabeledContent("Role Session Name", value: draft.roleSessionName ?? "—")
                LabeledContent("MFA Serial", value: draft.mfaSerial ?? "—")
            } else {
                TextField("Role ARN", text: $draft.roleArn.unwrapped(), prompt: Text("arn:aws:iam::123456789012:role/MyRole"))
                TextField("Source Profile", text: $draft.sourceProfile.unwrapped(), prompt: Text("default"))
                TextField("Role Session Name", text: $draft.roleSessionName.unwrapped(), prompt: Text("my-session"))
                TextField("MFA Serial", text: $draft.mfaSerial.unwrapped(), prompt: Text("arn:aws:iam::123456789012:mfa/user"))
            }
        }
    }

    @ViewBuilder private var credentialProcessSection: some View {
        Section("Credential Process") {
            if isReadOnly {
                LabeledContent("Command", value: draft.credentialProcess ?? "—")
            } else {
                TextField("Command", text: $draft.credentialProcess.unwrapped(), prompt: Text("/path/to/helper --profile name"))
                    .fontDesign(.monospaced)
            }
        }
    }
}

#Preview("Edit mode (clean)") {
    ProfileDetailPreviewHarness(mode: .managed)
}

#Preview("Read Only") {
    ProfileDetailPreviewHarness(mode: .readOnly)
}

#Preview("Profile not found") {
    ContentUnavailableView("Profile not found", systemImage: "questionmark.circle")
}

private struct ProfileDetailPreviewHarness: View {
    let mode: ManagedMode
    @State private var selection: SidebarSelection? = .profile(name: "default")
    @State private var appModel: AppModel
    @State private var profilesModel = ProfilesModel()
    @State private var editorState = EditorState()

    init(mode: ManagedMode) {
        self.mode = mode
        let tmp = URL(filePath: "/nonexistent/aws-folder")
        _appModel = State(initialValue: AppModel(initialPhase: .ready(tmp), initialMode: mode))
    }

    var body: some View {
        Group {
            if case .loaded = profilesModel.loadState,
               let node = profilesModel.findProfile(named: "default") {
                ProfileDetailView(node: node, sidebarSelection: $selection)
                    .environment(appModel)
                    .environment(profilesModel)
                    .environment(editorState)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task {
            let tmp = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            try? sampleConfig.write(
                to: tmp.appending(path: "config", directoryHint: .notDirectory),
                atomically: true,
                encoding: .utf8
            )
            appModel = AppModel(initialPhase: .ready(tmp), initialMode: mode)
            await profilesModel.load(folder: tmp)
        }
    }

    private var sampleConfig: String {
        """
        [sso-session acme]
        sso_start_url = https://acme.awsapps.com/start
        sso_region = us-east-1
        sso_registration_scopes = sso:account:access

        [default]
        sso_session = acme
        sso_account_id = 412903117204
        sso_role_name = AdministratorAccess
        region = us-east-1
        output = json

        [profile assume-billing]
        role_arn = arn:aws:iam::412903117204:role/Billing
        source_profile = default
        """
    }
}
