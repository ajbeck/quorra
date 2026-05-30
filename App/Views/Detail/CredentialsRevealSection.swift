import SwiftUI
import AppKit
import IAMIdentityCenter

/// The "Credentials" section of `ProfileDetailView` for SSO-backed profiles (D31).
///
/// One `DisclosureGroup` (HIG: at most one disclosure per view). Collapsed by default — no
/// mint happens until the user expands it. On expand it calls `model.liveCredentials(...)`
/// (D26: cached-if-fresh, mint-if-stale, single-flight). The fetched `RoleCredentials` lives
/// ONLY in this view's `@State` and is cleared when the section collapses or disappears —
/// secret material never enters the observable model (D31 security posture). Mint progress /
/// terminal access denial flow through the model's overlay Sets for the inline advisories.
///
/// Read-only mode is orthogonal: minting writes to the Keychain, copy writes to the
/// clipboard — neither touches `~/.aws/*`, so this section is fully live in read-only mode
/// (matches A1 D5).
struct CredentialsRevealSection: View {
    let sessionName: String
    let accountId: String
    let roleName: String
    let region: String
    var onSignIn: (() -> Void)?
    var onViewSession: (() -> Void)?

    @Environment(CredentialsModel.self) private var model
    @Environment(\.authBrowserPresenter) private var authBrowserPresenter

    @State private var expanded = false
    @State private var creds: RoleCredentials?
    @State private var fetchError: IAMIdentityCenterError?
    @State private var isFetching = false
    @State private var revealed: Set<Field> = []

    private enum Field: Hashable { case accessKeyId, secretAccessKey, sessionToken }

    private var key: String { "\(sessionName):\(accountId):\(roleName)" }

    private var status: ProfileAuthStatus {
        model.profileStatus[key] ?? .ready(expiresAt: nil)
    }
    private var isMinting: Bool { model.mintingNow.contains(key) }
    private var hasMintFailure: Bool { model.mintFailure.contains(key) }
    private var isRoleRejected: Bool { model.roleRejected.contains(key) }
    private var sessionStatus: SessionAuthStatus? { model.status[sessionName] }
    private var signInProgress: SignInProgress? { model.inFlight[sessionName] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .signingIn = sessionStatus {
                signingInView(progress: signInProgress)
            } else {
                switch status {
                case .notSignedIn(let session):
                    signInRequired(session: session, reason: .notSignedIn)
                case .signInExpired(let session):
                    signInRequired(session: session, reason: .expired)
                case .ready where isRoleRejected:
                    advisory(
                        systemImage: "xmark.shield",
                        tint: .red,
                        text: "This role is no longer available. Contact your administrator.",
                        retry: false
                    )
                case .ready:
                    DisclosureGroup("Show credentials", isExpanded: $expanded) {
                        disclosureBody
                            .padding(.top, 12)
                    }
                }
            }
        }
        .onChange(of: expanded) { _, isOpen in
            if isOpen {
                Task { await fetch() }
            } else {
                // Collapse re-masks and drops secret material from memory.
                creds = nil
                fetchError = nil
                revealed.removeAll()
            }
        }
        .onDisappear {
            creds = nil
            revealed.removeAll()
        }
        .task {
            await model.observeProfileStatus(forSession: sessionName, accountId: accountId, roleName: roleName)
        }
        .onChange(of: status) { oldValue, newValue in
            guard case .ready = newValue else { return }
            fetchError = nil
            if case .ready = oldValue {
                return
            }
            guard expanded else { return }
            Task { await fetch(force: true) }
        }
    }

    // MARK: - Not-signed-in state

    private enum SignInReason {
        case notSignedIn
        case expired
    }

    @ViewBuilder private func signInRequired(session: String, reason: SignInReason) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: reason == .expired ? "exclamationmark.triangle.fill" : "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(reason == .expired ? Color.orange : Color.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(reason == .expired ? "Session expired" : "Sign in required")
                        .font(.callout.weight(.semibold))
                    Text(reason == .expired
                         ? "Sign in to \(session) again to refresh this profile's credentials."
                         : "Sign in to \(session) to mint credentials for this profile.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button {
                        onSignIn?()
                    } label: {
                        Label(reason == .expired ? "Sign in to refresh credentials" : "Sign in", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(onSignIn == nil)

                    if let onViewSession {
                        Button {
                            onViewSession()
                        } label: {
                            Label("View SSO session", systemImage: "arrow.up.right.square")
                        }
                    }
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder private func signingInView(progress: SignInProgress?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Waiting for IAM Identity Center sign-in")
                        .font(.callout.weight(.semibold))
                    Text("Complete the browser step to refresh this profile's credentials.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let progress {
                LabeledContent("User code") {
                    Text(progress.userCode)
                        .font(.body.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    Button("Open browser again") {
                        authBrowserPresenter.present(progress.verificationUriComplete)
                    }

                    Text("Expires in")
                        .foregroundStyle(.secondary)
                    Text(timerInterval: Date.now...progress.expiresAt, countsDown: true)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            Button("Cancel", role: .cancel) {
                Task { await model.cancelSignIn(sessionName: sessionName) }
            }
            .controlSize(.small)
        }
    }

    // MARK: - Disclosure body (ready state)

    @ViewBuilder private var disclosureBody: some View {
        // roleRejected is handled at the section level (HIG / D31 amendment) and never
        // reaches the disclosure body.
        if isMinting || isFetching {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(isMinting ? "Refreshing credentials…" : "Loading credentials…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if let creds {
            credentialFields(creds)
            if hasMintFailure {
                advisory(
                    systemImage: "exclamationmark.triangle",
                    tint: .orange,
                    text: "Last refresh failed. Showing the most recent credentials.",
                    retry: true
                )
            }
        } else if let fetchError {
            advisory(
                systemImage: "exclamationmark.triangle",
                tint: .orange,
                text: errorText(fetchError),
                retry: !fetchError.isTerminalRoleError
            )
        } else {
            // Expanded but fetch hasn't resolved yet (transient window).
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading credentials…").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Credential fields

    @ViewBuilder private func credentialFields(_ c: RoleCredentials) -> some View {
        credentialRow("AWS_ACCESS_KEY_ID", value: c.accessKeyId, field: .accessKeyId, fingerprint: true)
        credentialRow("AWS_SECRET_ACCESS_KEY", value: c.secretAccessKey, field: .secretAccessKey, fingerprint: false)
        credentialRow("AWS_SESSION_TOKEN", value: c.sessionToken, field: .sessionToken, fingerprint: false)

        LabeledContent("Expires") {
            Text(c.expiresAt, format: .relative(presentation: .named))
                .foregroundStyle(c.expiresAt > Date() ? .secondary : Color.red)
                .monospacedDigit()
        }

        HStack {
            Button("Copy as environment variables") { copyEnvVars(c) }
                .buttonStyle(.bordered)
            Button("Copy as config block") { copyConfigBlock(c) }
                .buttonStyle(.bordered)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    @ViewBuilder private func credentialRow(
        _ label: String,
        value: String,
        field: Field,
        fingerprint: Bool
    ) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Text(revealed.contains(field) ? value : mask(value, fingerprint: fingerprint))
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button {
                    revealed.formSymmetricDifference([field])
                } label: {
                    Image(systemName: revealed.contains(field) ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealed.contains(field) ? "Hide" : "Reveal")

                Button {
                    copyToPasteboard(value)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
        }
    }

    // MARK: - Advisory

    @ViewBuilder private func advisory(
        systemImage: String,
        tint: Color,
        text: String,
        retry: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(text)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
            .font(.callout)
            if retry {
                Button("Retry") { Task { await fetch(force: true) } }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Fetch

    private func fetch(force: Bool = false) async {
        // Terminal access-denied: a mint would just be re-rejected. Don't fire a doomed
        // Portal call — the roleRejected advisory (driven by the overlay) already explains
        // the state and offers no Retry (D31).
        if isRoleRejected { return }
        if !force && creds != nil { return }
        isFetching = true
        fetchError = nil
        defer { isFetching = false }
        do {
            creds = try await model.liveCredentials(
                forSession: sessionName,
                accountId: accountId,
                roleName: roleName,
                region: region
            )
        } catch let e as IAMIdentityCenterError {
            creds = nil
            fetchError = e
        } catch {
            creds = nil
            fetchError = .network(error as? URLError ?? URLError(.unknown))
        }
    }

    // MARK: - Masking

    private func mask(_ value: String, fingerprint: Bool) -> String {
        guard fingerprint, value.count > 8 else {
            return String(repeating: "•", count: max(12, min(value.count, 24)))
        }
        return "\(value.prefix(4))••••••••\(value.suffix(4))"
    }

    // MARK: - Clipboard

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func copyEnvVars(_ c: RoleCredentials) {
        copyToPasteboard("""
        export AWS_ACCESS_KEY_ID=\(c.accessKeyId)
        export AWS_SECRET_ACCESS_KEY=\(c.secretAccessKey)
        export AWS_SESSION_TOKEN=\(c.sessionToken)
        """)
    }

    private func copyConfigBlock(_ c: RoleCredentials) {
        copyToPasteboard("""
        [profile temp]
        aws_access_key_id = \(c.accessKeyId)
        aws_secret_access_key = \(c.secretAccessKey)
        aws_session_token = \(c.sessionToken)
        """)
    }

    private func errorText(_ e: IAMIdentityCenterError) -> String {
        if e.isTerminalRoleError {
            return "This role is no longer available. Contact your administrator."
        }
        if e.requiresSignIn {
            return "Session expired. Sign in again to refresh this profile's credentials."
        }
        return "Couldn't fetch credentials. \(e.localizedDescription)"
    }
}

private extension IAMIdentityCenterError {
    /// Terminal access-denied errors (admin must restore access) — no Retry offered.
    var isTerminalRoleError: Bool {
        switch self {
        case .roleNotAssigned, .accountNotFound:
            return true
        default:
            return false
        }
    }

    var requiresSignIn: Bool {
        switch self {
        case .tokenExpired, .invalidGrant, .invalidClient, .expiredDeviceCode, .deviceFlowTimedOut:
            return true
        default:
            return false
        }
    }
}

// MARK: - Previews

private struct RevealPreviewHarness: View {
    let seed: (CredentialsModel) -> Void
    @State private var model = CredentialsModel(service: PreviewIdentityCenterService())

    var body: some View {
        DetailCard("Credentials") {
            CredentialsRevealSection(
                sessionName: "acme",
                accountId: "123456789012",
                roleName: "AdministratorAccess",
                region: "us-east-1",
                onSignIn: {},
                onViewSession: {}
            )
            .environment(model)
        }
        .frame(width: 460)
        .task { seed(model) }
    }
}

#Preview("ready (collapsed)") {
    RevealPreviewHarness { m in
        m.seedProfileStatusForTesting(.ready(expiresAt: Date().addingTimeInterval(3000)),
                                      key: "acme:123456789012:AdministratorAccess")
    }
}

#Preview("not signed in") {
    RevealPreviewHarness { m in
        m.seedProfileStatusForTesting(.notSignedIn(sessionName: "acme"),
                                      key: "acme:123456789012:AdministratorAccess")
    }
}

#Preview("expired") {
    RevealPreviewHarness { m in
        m.seedProfileStatusForTesting(.signInExpired(sessionName: "acme"),
                                      key: "acme:123456789012:AdministratorAccess")
    }
}

#Preview("signing in") {
    RevealPreviewHarness { m in
        m.seedProfileStatusForTesting(.signInExpired(sessionName: "acme"),
                                      key: "acme:123456789012:AdministratorAccess")
        m.seedStatusForTesting(.signingIn, sessionName: "acme")
        m.seedInFlightForTesting(
            SignInProgress(
                sessionName: "acme",
                verification: DeviceVerification(
                    userCode: "ABCD-EFGH",
                    verificationUri: URL(string: "https://device.sso.us-east-1.amazonaws.com")!,
                    verificationUriComplete: URL(string: "https://device.sso.us-east-1.amazonaws.com?user_code=ABCD-EFGH")!,
                    expiresAt: Date().addingTimeInterval(600),
                    interval: 5
                )
            ),
            sessionName: "acme"
        )
    }
}

#Preview("ready + roleRejected") {
    RevealPreviewHarness { m in
        m.seedProfileStatusForTesting(.ready(expiresAt: nil),
                                      key: "acme:123456789012:AdministratorAccess")
        m.seedRoleRejectedForTesting(key: "acme:123456789012:AdministratorAccess")
    }
}

#Preview("ready + minting") {
    RevealPreviewHarness { m in
        m.seedProfileStatusForTesting(.ready(expiresAt: nil),
                                      key: "acme:123456789012:AdministratorAccess")
        m.seedMintingNowForTesting(key: "acme:123456789012:AdministratorAccess")
    }
}
