import SwiftUI
import IAMIdentityCenter
import QuorraAppLogic
import SwiftData

struct SessionDetailView: View {
    let session: SessionDefinition
    @Environment(CredentialsModel.self) private var credentialsModel
    @Environment(EditorState.self) private var editorState
    @Environment(\.modelContext) private var modelContext
    @State private var draft: SessionDraft
    @State private var saveError: String?

    init(session: SessionDefinition) {
        self.session = session
        self._draft = State(initialValue: SessionDraft(session))
    }

    private var stored: SessionDraft { SessionDraft(session) }
    private var isDirty: Bool { draft != stored }

    var body: some View {
        Form {
            identitySection
            scopesSection
            statusSection
        }
        .formStyle(.grouped)
        .navigationTitle(session.name)
        .navigationSubtitle(isDirty ? "Edited" : "")
        .toolbar { editorToolbar }
        .onChange(of: stored) { _, newValue in
            draft = newValue
        }
        .onChange(of: isDirty) { _, newValue in
            editorState.dirtyDescription = newValue ? "changes to session \(session.name)" : nil
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

    @ToolbarContentBuilder private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Discard", role: .destructive) {
                draft = stored
            }
            .disabled(!isDirty)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save") { save() }
                .disabled(!isDirty)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func save() {
        if let message = draft.validationMessage {
            saveError = message
            return
        }
        draft.apply(to: session)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            saveError = error.localizedDescription
        }
    }

    @ViewBuilder private var identitySection: some View {
        Section("Identity") {
            TextField("Start URL", text: $draft.startURL, prompt: Text("https://my-domain.awsapps.com/start"))
                .fontDesign(.monospaced)
            TextField("Region", text: $draft.region, prompt: Text("us-east-1"))
                .fontDesign(.monospaced)
        }
    }

    @ViewBuilder private var scopesSection: some View {
        Section("Scopes") {
            TextField("Registration Scopes", text: scopesText, prompt: Text("sso:account:access"))
        }
    }

    private var scopesText: Binding<String> {
        Binding(
            get: { draft.registrationScopes.joined(separator: ", ") },
            set: { draft.registrationScopes = AddSessionSheet.scopes(from: $0) }
        )
    }

    @ViewBuilder private var statusSection: some View {
        Section("Status") {
            SignInPanel(
                sessionName: session.name,
                startUrl: URL(string: session.startURL),
                region: session.region,
                scopes: session.registrationScopes,
                authStatus: credentialsModel.status[session.name] ?? .signedOut,
                progress: credentialsModel.inFlight[session.name],
                lastError: credentialsModel.lastError[session.name],
                signOutFailed: credentialsModel.signOutFailure.contains(session.name),
                isReadOnly: false,
                isRefreshing: credentialsModel.refreshingNow.contains(session.name),
                hasRefreshFailure: credentialsModel.refreshFailure.contains(session.name),
                onSignIn: { triggerSignIn() },
                onCancel: {
                    Task {
                        await credentialsModel.cancelSignIn(sessionName: session.name)
                    }
                },
                onSignOut: {
                    Task {
                        await credentialsModel.signOut(sessionName: session.name)
                    }
                },
                onRefreshNow: {
                    Task {
                        await credentialsModel.refreshNow(sessionName: session.name)
                    }
                }
            )
        }
    }

    /// Signs in with the stored values; unsaved edits do not take part until they are saved.
    private func triggerSignIn() {
        guard let startUrl = URL(string: session.startURL) else { return }
        let sessionName = session.name
        let region = session.region
        let scopes = session.registrationScopes
        Task {
            await credentialsModel.signIn(
                sessionName: sessionName,
                startUrl: startUrl,
                region: region,
                scopes: scopes
            )
        }
    }
}

#if DEBUG

#Preview("Idle") {
    SessionDetailPreviewHarness(previewState: .idle)
}

#Preview("Signing in") {
    SessionDetailPreviewHarness(previewState: .signingIn)
}

#Preview("Sign-in failed") {
    SessionDetailPreviewHarness(previewState: .failed)
}

#Preview("Signed in") {
    SessionDetailPreviewHarness(previewState: .signedIn)
}

#Preview("Expired – needs sign in") {
    SessionDetailPreviewHarness(previewState: .expiredNeedsSignIn)
}

#Preview("Expired – refresh available") {
    SessionDetailPreviewHarness(previewState: .expiredRefreshAvailable)
}

#Preview("Sign-out advisory") {
    SessionDetailPreviewHarness(previewState: .signOutAdvisory)
}

#Preview("Refreshing overlay") {
    SessionDetailPreviewHarness(previewState: .refreshing)
}

#Preview("Refresh transient failure") {
    SessionDetailPreviewHarness(previewState: .refreshTransientFailure)
}

#Preview("Signed in – canRefresh false") {
    SessionDetailPreviewHarness(previewState: .signedInNoRefresh)
}

private enum PreviewState {
    case idle
    case signingIn
    case failed
    case signedIn
    case expiredNeedsSignIn
    case expiredRefreshAvailable
    case signOutAdvisory
    case refreshing
    case refreshTransientFailure
    case signedInNoRefresh
}

private struct SessionDetailPreviewHarness: View {
    private static let sessionName = "astrocompute"

    @State private var credentialsModel = CredentialsModel(service: PreviewIdentityCenterService())
    @State private var editorState = EditorState()
    private let metadataContainer = PreviewIdentityFixtures.makeContainer()
    private let session: SessionDefinition
    private let previewState: PreviewState

    init(previewState: PreviewState) {
        self.previewState = previewState
        session = try! IdentityStore.session(named: Self.sessionName, in: metadataContainer.mainContext)!
    }

    var body: some View {
        SessionDetailView(session: session)
            .environment(credentialsModel)
            .environment(editorState)
            .modelContainer(metadataContainer)
            .task { seedCredentialState() }
    }

    private func seedCredentialState() {
        let name = Self.sessionName
        switch previewState {
        case .idle:
            break
        case .signingIn:
            let progress = SignInProgress(
                sessionName: name,
                verification: DeviceVerification(
                    userCode: "ABCD-EFGH",
                    verificationUri: URL(string: "https://device.sso.us-east-2.amazonaws.com")!,
                    verificationUriComplete: URL(string: "https://device.sso.us-east-2.amazonaws.com?user_code=ABCD-EFGH")!,
                    expiresAt: Date(timeIntervalSinceNow: 600),
                    interval: 5
                )
            )
            credentialsModel.seedInFlightForTesting(progress, sessionName: name)
            credentialsModel.seedStatusForTesting(.signingIn, sessionName: name)
        case .failed:
            credentialsModel.seedLastErrorForTesting(.expiredDeviceCode, sessionName: name)
            credentialsModel.seedStatusForTesting(.signedOut, sessionName: name)
        case .signedIn:
            credentialsModel.seedStatusForTesting(
                .signedIn(expiresAt: Date(timeIntervalSinceNow: 8 * 3600), canRefresh: true),
                sessionName: name
            )
        case .expiredNeedsSignIn:
            credentialsModel.seedStatusForTesting(
                .expired(expiredAt: Date(timeIntervalSinceNow: -60), canRefresh: false),
                sessionName: name
            )
        case .expiredRefreshAvailable:
            credentialsModel.seedStatusForTesting(
                .expired(expiredAt: Date(timeIntervalSinceNow: -60), canRefresh: true),
                sessionName: name
            )
        case .signOutAdvisory:
            credentialsModel.seedStatusForTesting(.signedOut, sessionName: name)
            credentialsModel.seedSignOutFailureForTesting(sessionName: name)
        case .refreshing:
            credentialsModel.seedStatusForTesting(
                .signedIn(expiresAt: Date(timeIntervalSinceNow: 3600), canRefresh: true),
                sessionName: name
            )
            credentialsModel.seedRefreshingNowForTesting(sessionName: name)
        case .refreshTransientFailure:
            credentialsModel.seedStatusForTesting(
                .signedIn(expiresAt: Date(timeIntervalSinceNow: 3600), canRefresh: true),
                sessionName: name
            )
            credentialsModel.seedRefreshFailureForTesting(sessionName: name)
        case .signedInNoRefresh:
            credentialsModel.seedStatusForTesting(
                .signedIn(expiresAt: Date(timeIntervalSinceNow: 3600), canRefresh: false),
                sessionName: name
            )
        }
    }
}

#endif
