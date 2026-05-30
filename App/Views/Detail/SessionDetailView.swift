import SwiftUI
import AWSConfigINI
import IAMIdentityCenter

struct SessionDetailView: View {
    let node: SSOSessionNode
    @Environment(AppModel.self) private var appModel
    @Environment(ProfilesModel.self) private var profilesModel
    @Environment(CredentialsModel.self) private var credentialsModel
    @Environment(EditorState.self) private var editorState
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
        .toolbar { editorToolbar }
        .onChange(of: node) { _, newValue in
            draft = newValue.session ?? SSOSession()
        }
        .onChange(of: isDirty) { _, newValue in
            editorState.dirtyDescription = newValue ? "changes to SSO session \(node.id)" : nil
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
                    draft = node.session ?? SSOSession()
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
                    .accessibilityHidden(true)
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
            SignInPanel(
                sessionName: node.id,
                startUrl: draft.ssoStartUrl.flatMap { URL(string: $0) },
                region: draft.ssoRegion,
                scopes: draft.ssoRegistrationScopes,
                authStatus: credentialsModel.status[node.id] ?? .signedOut,
                progress: credentialsModel.inFlight[node.id],
                lastError: credentialsModel.lastError[node.id],
                signOutFailed: credentialsModel.signOutFailure.contains(node.id),
                isReadOnly: isReadOnly,
                // A2 (D17): refreshing overlay from CredentialsModel
                isRefreshing: credentialsModel.refreshingNow.contains(node.id),
                // A2 (D16): transient failure advisory
                hasRefreshFailure: credentialsModel.refreshFailure.contains(node.id),
                onSignIn: { triggerSignIn() },
                onCancel: {
                    Task {
                        await credentialsModel.cancelSignIn(sessionName: node.id)
                    }
                },
                onSignOut: {
                    Task {
                        await credentialsModel.signOut(sessionName: node.id)
                    }
                },
                // A2 (D16): "Refresh now" button in transient-failure advisory
                onRefreshNow: {
                    Task {
                        await credentialsModel.refreshNow(sessionName: node.id)
                    }
                }
            )
        }
    }

    private func triggerSignIn() {
        guard let startUrlString = draft.ssoStartUrl,
              let startUrl = URL(string: startUrlString),
              let region = draft.ssoRegion else {
            return
        }
        let scopes = draft.ssoRegistrationScopes ?? ["sso:account:access"]
        Task {
            await credentialsModel.signIn(
                sessionName: node.id,
                startUrl: startUrl,
                region: region,
                scopes: scopes
            )
        }
    }
}

#Preview("Idle") {
    SessionDetailPreviewHarness(mode: .managed, previewState: .idle)
}

#Preview("Signing in") {
    SessionDetailPreviewHarness(mode: .managed, previewState: .signingIn)
}

#Preview("Sign-in failed") {
    SessionDetailPreviewHarness(mode: .managed, previewState: .failed)
}

#Preview("Signed in") {
    SessionDetailPreviewHarness(mode: .managed, previewState: .signedIn)
}

#Preview("Expired – needs sign in") {
    SessionDetailPreviewHarness(mode: .managed, previewState: .expiredNeedsSignIn)
}

#Preview("Sign-out advisory") {
    SessionDetailPreviewHarness(mode: .managed, previewState: .signOutAdvisory)
}

#Preview("Read Only – signed in") {
    SessionDetailPreviewHarness(mode: .readOnly, previewState: .signedIn)
}

// A2 previews (D16, D17)
#Preview("Refreshing overlay") {
    SessionDetailPreviewHarness(mode: .managed, previewState: .refreshing)
}

#Preview("Refresh transient failure") {
    SessionDetailPreviewHarness(mode: .managed, previewState: .refreshTransientFailure)
}

#Preview("Signed in – canRefresh false") {
    SessionDetailPreviewHarness(mode: .managed, previewState: .signedInNoRefresh)
}

private enum PreviewState {
    case idle
    case signingIn
    case failed
    case signedIn
    case expiredNeedsSignIn
    case signOutAdvisory
    // A2
    case refreshing
    case refreshTransientFailure
    case signedInNoRefresh
}

private struct SessionDetailPreviewHarness: View {
    let mode: ManagedMode
    let previewState: PreviewState
    @State private var appModel: AppModel
    @State private var profilesModel = ProfilesModel()
    @State private var credentialsModel: CredentialsModel
    @State private var editorState = EditorState()

    init(mode: ManagedMode, previewState: PreviewState) {
        self.mode = mode
        self.previewState = previewState
        let tmp = URL(filePath: "/nonexistent/aws-folder")
        _appModel = State(initialValue: AppModel(initialPhase: .ready(tmp), initialMode: mode))
        _credentialsModel = State(initialValue: CredentialsModel(service: PreviewIdentityCenterService()))
    }

    var body: some View {
        Group {
            if case .loaded = profilesModel.loadState,
               let node = profilesModel.findSession(named: "acme") {
                SessionDetailView(node: node)
                    .environment(appModel)
                    .environment(profilesModel)
                    .environment(credentialsModel)
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

            switch previewState {
            case .idle:
                break
            case .signingIn:
                let progress = SignInProgress(
                    sessionName: "acme",
                    verification: DeviceVerification(
                        userCode: "ABCD-EFGH",
                        verificationUri: URL(string: "https://device.sso.us-east-1.amazonaws.com")!,
                        verificationUriComplete: URL(string: "https://device.sso.us-east-1.amazonaws.com?user_code=ABCD-EFGH")!,
                        expiresAt: Date(timeIntervalSinceNow: 600),
                        interval: 5
                    )
                )
                credentialsModel.seedInFlightForTesting(progress, sessionName: "acme")
                credentialsModel.seedStatusForTesting(.signingIn, sessionName: "acme")
            case .failed:
                credentialsModel.seedLastErrorForTesting(.expiredDeviceCode, sessionName: "acme")
                credentialsModel.seedStatusForTesting(.signedOut, sessionName: "acme")
            case .signedIn:
                credentialsModel.seedStatusForTesting(
                    .signedIn(expiresAt: Date(timeIntervalSinceNow: 8 * 3600), canRefresh: true),
                    sessionName: "acme"
                )
            case .expiredNeedsSignIn:
                credentialsModel.seedStatusForTesting(
                    .expired(expiredAt: Date(timeIntervalSinceNow: -60), canRefresh: false),
                    sessionName: "acme"
                )
            case .signOutAdvisory:
                credentialsModel.seedStatusForTesting(.signedOut, sessionName: "acme")
                credentialsModel.seedSignOutFailureForTesting(sessionName: "acme")
            case .refreshing:
                credentialsModel.seedStatusForTesting(
                    .signedIn(expiresAt: Date(timeIntervalSinceNow: 3600), canRefresh: true),
                    sessionName: "acme"
                )
                credentialsModel.seedRefreshingNowForTesting(sessionName: "acme")
            case .refreshTransientFailure:
                credentialsModel.seedStatusForTesting(
                    .signedIn(expiresAt: Date(timeIntervalSinceNow: 3600), canRefresh: true),
                    sessionName: "acme"
                )
                credentialsModel.seedRefreshFailureForTesting(sessionName: "acme")
            case .signedInNoRefresh:
                credentialsModel.seedStatusForTesting(
                    .signedIn(expiresAt: Date(timeIntervalSinceNow: 3600), canRefresh: false),
                    sessionName: "acme"
                )
            }
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
