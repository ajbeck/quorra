import SwiftUI
import AWSConfigINI

struct SessionDetailView: View {
    let node: SSOSessionNode
    @Environment(AppModel.self) private var appModel
    @Environment(\.openSettings) private var openSettings
    @State private var draft: SSOSession
    @State private var isPresentingSaveError = false
    @State private var saveError: AWSConfigINIError?

    init(node: SSOSessionNode) {
        self.node = node
        self._draft = State(initialValue: node.session ?? SSOSession())
    }

    private var isReadOnly: Bool { appModel.mode == .readOnly }
    private var isDirty: Bool { draft != (node.session ?? SSOSession()) }

    var body: some View {
        Form {
            if isReadOnly { readOnlyBanner }
            identitySection
            scopesSection
            statusSection
        }
        .formStyle(.grouped)
        .navigationTitle(node.id)
        .navigationSubtitle(isDirty ? "Edited" : "")
        .onChange(of: node) { _, newValue in
            draft = newValue.session ?? SSOSession()
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
                LabeledContent("Start URL", value: draft.ssoStartUrl ?? "—")
                LabeledContent("Region", value: draft.ssoRegion ?? "—")
            } else {
                TextField("Start URL", text: $draft.ssoStartUrl.unwrapped(), prompt: Text("https://my-domain.awsapps.com/start"))
                    .fontDesign(.monospaced)
                TextField("Region", text: $draft.ssoRegion.unwrapped(), prompt: Text("us-east-1"))
                    .fontDesign(.monospaced)
            }
        }
    }

    @ViewBuilder private var scopesSection: some View {
        Section("Scopes") {
            if isReadOnly {
                LabeledContent("Registration Scopes", value: (draft.ssoRegistrationScopes ?? []).joined(separator: ", ").isEmpty ? "—" : (draft.ssoRegistrationScopes ?? []).joined(separator: ", "))
            } else {
                TextField(
                    "Registration Scopes",
                    text: $draft.ssoRegistrationScopes.commaJoinedString(),
                    prompt: Text("sso:account:access")
                )
            }
        }
    }

    @ViewBuilder private var statusSection: some View {
        Section("Status") {
            Text("Sign-in not yet implemented in this build")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview("Edit mode") {
    SessionDetailPreviewHarness(mode: .managed)
}

#Preview("Read Only") {
    SessionDetailPreviewHarness(mode: .readOnly)
}

private struct SessionDetailPreviewHarness: View {
    let mode: ManagedMode
    @State private var appModel: AppModel
    @State private var profilesModel = ProfilesModel()

    init(mode: ManagedMode) {
        self.mode = mode
        let tmp = URL(filePath: "/nonexistent/aws-folder")
        _appModel = State(initialValue: AppModel(initialPhase: .ready(tmp), initialMode: mode))
    }

    var body: some View {
        Group {
            if case .loaded = profilesModel.loadState,
               let node = profilesModel.findSession(named: "acme") {
                SessionDetailView(node: node)
                    .environment(appModel)
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
        """
    }
}
