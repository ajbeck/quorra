import SwiftUI
import AppKit
import IAMIdentityCenter
import QuorraAppLogic

/// The "Credentials" section of `ProfileDetailView` for SSO-backed profiles (D31).
///
/// The fetched `RoleCredentials` lives ONLY in this view's `@State` and is cleared when the
/// section disappears -- secret material never enters the observable model (D31 security
/// posture). Mint progress / terminal access denial flow through the model's overlay Sets for
/// the inline advisories.
///
/// Read-only mode is orthogonal: minting writes to the Keychain, copy writes to the
/// clipboard — neither touches `~/.aws/*`, so this section is fully live in read-only mode
/// (matches A1 D5).
struct CredentialsRevealSection: View {
    let profileName: String
    let sessionName: String
    let accountId: String
    let roleName: String
    let region: String
    let imdsEndpointCount: Int
    var onSignIn: (() -> Void)?
    var onViewIMDS: (() -> Void)?
    var onCreateIMDS: (() -> Void)?
    var onViewSession: (() -> Void)?

    @Environment(CredentialsModel.self) private var model
    @Environment(\.authBrowserPresenter) private var authBrowserPresenter

    @State private var selectedShell: CredentialShell = .bash
    @State private var creds: RoleCredentials?
    @State private var fetchError: IAMIdentityCenterError?
    @State private var isFetching = false
    @State private var revealed: Set<Field> = []

    private enum Field: Hashable { case accessKeyId, secretAccessKey, sessionToken }
    private enum DisplayState: Equatable {
        case checking
        case signingIn
        case notSignedIn(sessionName: String)
        case expired(sessionName: String)
        case roleRejected
        case ready
    }

    private enum CredentialShell: String, CaseIterable, Identifiable {
        case bash
        case zsh
        case fish
        case powershell

        var id: String { rawValue }
        var label: String { rawValue }
        var isAvailable: Bool { self == .bash }
    }

    private var key: String { "\(sessionName):\(accountId):\(roleName)" }

    private var status: ProfileAuthStatus? { model.profileStatus[key] }
    private var isMinting: Bool { model.mintingNow.contains(key) }
    private var hasMintFailure: Bool { model.mintFailure.contains(key) }
    private var isRoleRejected: Bool { model.roleRejected.contains(key) }
    private var sessionStatus: SessionAuthStatus? { model.status[sessionName] }
    private var signInProgress: SignInProgress? { model.inFlight[sessionName] }
    private var displayState: DisplayState {
        if case .signingIn = sessionStatus {
            return .signingIn
        }

        guard let status else {
            return .checking
        }

        switch status {
        case .notSignedIn(let session):
            return .notSignedIn(sessionName: session)
        case .signInExpired(let session):
            return .expired(sessionName: session)
        case .ready where hasTerminalCredentialError:
            return .roleRejected
        case .ready:
            return .ready
        }
    }

    private var isCredentialReady: Bool {
        displayState == .ready
    }

    private var hasTerminalCredentialError: Bool {
        isRoleRejected || fetchError?.isTerminalRoleError == true
    }

    private var expiresAt: Date? {
        if let creds { return creds.expiresAt }
        if case .ready(let expiresAt) = status { return expiresAt }
        return nil
    }

    private var credentialExportPreview: String {
        "export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            credentialStatusHeader
            shellAndCommand
            imdsControlRow
            credentialStateDetails
            credentialMaterial
        }
        .onDisappear {
            creds = nil
            revealed.removeAll()
        }
        .onChange(of: status) { oldValue, newValue in
            guard case .ready = newValue else {
                creds = nil
                fetchError = nil
                return
            }
            fetchError = nil
            Task { await fetch(force: oldValue != newValue) }
        }
        .task(id: key) {
            resetCredentialStateForProfileChange()
            await model.observeProfileStatus(forSession: sessionName, accountId: accountId, roleName: roleName)
            guard case .ready = status else { return }
            await fetch()
        }
    }

    // MARK: - State-aware shell

    private var credentialStatusHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                credentialStateBlock
                credentialStateCaption
                Spacer(minLength: 16)
                credentialPrimaryAction
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 16) {
                    credentialStateBlock
                    credentialStateCaption
                    Spacer(minLength: 0)
                }
                credentialPrimaryAction
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    @ViewBuilder private var credentialStateBlock: some View {
        switch displayState {
        case .ready:
            TimelineView(.periodic(from: .now, by: 30)) { context in
                remainingTimeBlock(at: context.date)
            }
        case .checking:
            stateLabel("Checking", color: .secondary, systemImage: "hourglass")
        case .signingIn:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Signing in")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.primary)
            }
            .accessibilityElement(children: .combine)
        case .notSignedIn:
            stateLabel("Sign in", color: .secondary, systemImage: "person.crop.circle.badge.exclamationmark")
        case .expired:
            stateLabel("Expired", color: .red, systemImage: "exclamationmark.triangle.fill")
        case .roleRejected:
            stateLabel("Unavailable", color: .red, systemImage: "xmark.shield")
        }
    }

    private func stateLabel(_ text: String, color: Color, systemImage: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(color)
        }
    }

    private var credentialStateCaption: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(credentialStateTitle)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(credentialStateSubtitle)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var credentialStateTitle: String {
        switch displayState {
        case .ready:
            return "until temporary credentials expire"
        case .checking:
            return "checking credential availability"
        case .signingIn:
            return "waiting for IAM Identity Center"
        case .notSignedIn:
            return "sign in to mint temporary credentials"
        case .expired:
            return "temporary credentials are expired"
        case .roleRejected:
            return "role credentials cannot be minted"
        }
    }

    private var credentialStateSubtitle: String {
        switch displayState {
        case .ready:
            if let creds {
                return "minted \(creds.issuedAt.formatted(date: .omitted, time: .shortened))  ·  expires \(creds.expiresAt.formatted(date: .omitted, time: .shortened))"
            } else if let expiresAt {
                return "expires \(expiresAt.formatted(date: .omitted, time: .shortened))"
            }
            return "expiration unavailable"
        case .checking:
            return "\(sessionName) · \(accountId) · \(roleName)"
        case .signingIn:
            if let progress = signInProgress {
                return "code \(progress.userCode) · expires \(progress.expiresAt.formatted(date: .omitted, time: .shortened))"
            }
            return "\(sessionName) sign-in in progress"
        case .notSignedIn(let session):
            return "\(session) requires authentication"
        case .expired(let session):
            return "\(session) needs a fresh sign-in"
        case .roleRejected:
            return "\(accountId) · \(roleName)"
        }
    }

    @ViewBuilder private var credentialPrimaryAction: some View {
        switch displayState {
        case .ready:
            renewButton
        case .notSignedIn:
            Button {
                onSignIn?()
            } label: {
                Label("Sign in", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(onSignIn == nil)
        case .expired:
            Button {
                onSignIn?()
            } label: {
                Label("Sign in to refresh credentials", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(onSignIn == nil)
        case .signingIn:
            Button("Cancel", role: .cancel) {
                Task { await model.cancelSignIn(sessionName: sessionName) }
            }
            .controlSize(.small)
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .roleRejected:
            if let onViewSession {
                Button {
                    onViewSession()
                } label: {
                    Label("View SSO session", systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder private var credentialStateDetails: some View {
        switch displayState {
        case .checking:
            EmptyView()
        case .ready:
            if hasMintFailure {
                advisory(
                    systemImage: "exclamationmark.triangle",
                    tint: .orange,
                    text: "Last refresh failed. Showing the most recent credentials.",
                    retry: true
                )
            }
        case .signingIn:
            signingInDetails
        case .notSignedIn:
            recoveryDetails(
                systemImage: "person.crop.circle.badge.exclamationmark",
                tint: .secondary,
                text: "Sign in to \(sessionName) to mint credentials for this profile."
            )
        case .expired:
            recoveryDetails(
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange,
                text: "Sign in to \(sessionName) again to refresh this profile's credentials."
            )
        case .roleRejected:
            advisory(
                systemImage: "xmark.shield",
                tint: .red,
                text: "This role is no longer available. Contact your administrator.",
                retry: false
            )
        }
    }

    private func recoveryDetails(systemImage: String, tint: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Label {
                Text(text)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
            .font(.callout)

            if let onViewSession {
                Button {
                    onViewSession()
                } label: {
                    Label("View SSO session", systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder private var signingInDetails: some View {
        if let progress = signInProgress {
            HStack(spacing: 14) {
                LabeledContent("User code") {
                    Text(progress.userCode)
                        .font(.body.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                }

                Button("Open browser again") {
                    authBrowserPresenter.present(progress.verificationUriComplete)
                }
                .controlSize(.small)

                Text("Expires in")
                    .foregroundStyle(.secondary)
                Group {
                    if let interval = ExpirationCountdown.interval(until: progress.expiresAt) {
                        Text(timerInterval: interval, countsDown: true)
                    } else {
                        Text("Expired")
                    }
                }
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    @ViewBuilder private var credentialMaterial: some View {
        if isMinting || isFetching {
            loadingCredentialFields(text: isMinting ? "Refreshing credentials..." : "Loading credentials...")
        } else if isCredentialReady, let creds {
            credentialFields(creds)
        } else if isCredentialReady, let fetchError {
            advisory(
                systemImage: "exclamationmark.triangle",
                tint: .orange,
                text: errorText(fetchError),
                retry: !fetchError.isTerminalRoleError
            )
            unavailableCredentialFields(message: unavailableCredentialMessage)
        } else if isCredentialReady {
            loadingCredentialFields(text: "Loading credentials...")
        } else {
            unavailableCredentialFields(message: unavailableCredentialMessage)
        }
    }

    // MARK: - Header pieces

    @ViewBuilder private func remainingTimeBlock(at date: Date) -> some View {
        let components = remainingComponents(at: date)
        let textColor = remainingTextColor(at: date)

        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("\(components.hours)")
                .font(.system(size: 34, weight: .regular, design: .default))
                .monospacedDigit()
                .foregroundStyle(textColor)
            Text("h")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("\(components.minutes)")
                .font(.system(size: 34, weight: .regular, design: .default))
                .monospacedDigit()
                .foregroundStyle(textColor)
            Text("m")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("\(components.hours) hours \(components.minutes) minutes remaining")
    }

    private var renewButton: some View {
        Button {
            Task { await fetch(force: true, renew: true) }
        } label: {
            Label("Renew", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(isFetching || isMinting)
    }

    private var shellAndCommand: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Shell")
                    .font(.caption.weight(.medium))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Picker("Shell", selection: $selectedShell) {
                    ForEach(CredentialShell.allCases) { shell in
                        Text(shell.label)
                            .tag(shell)
                            .disabled(!shell.isAvailable)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 300)
                .onChange(of: selectedShell) { _, newValue in
                    if !newValue.isAvailable {
                        selectedShell = .bash
                    }
                }
            }

            commandRow
        }
    }

    private var commandRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("$")
                    .foregroundStyle(.secondary)
                Text(credentialExportPreview)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.callout.monospaced())
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(Color.black.opacity(0.28))

            Button {
                if let creds {
                    copyToPasteboard(credentialEnvironmentExports(for: creds))
                }
            } label: {
                ViewThatFits(in: .horizontal) {
                    Label("Copy env", systemImage: "doc.on.doc")
                    Image(systemName: "doc.on.doc")
                }
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 36)
            .disabled(creds == nil)
            .help(creds == nil ? "Credentials are loading." : "Copy AWS credential environment exports")
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.08))
        }
    }

    private var imdsControlRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                imdsSummary
                Spacer(minLength: 12)
                imdsControls
            }

            VStack(alignment: .leading, spacing: 10) {
                imdsSummary
                imdsControls
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.08))
        }
        .accessibilityElement(children: .combine)
    }

    private var imdsSummary: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(imdsEndpointCount > 0 ? Color.blue : Color.secondary)
                .frame(width: 28, height: 28)
                .background((imdsEndpointCount > 0 ? Color.blue : Color.secondary).opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("IMDS endpoints")
                    .font(.callout.weight(.semibold))
                Text(imdsSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var imdsControls: some View {
        HStack(spacing: 10) {
            if imdsEndpointCount > 0, let onViewIMDS {
                Button {
                    onViewIMDS()
                } label: {
                    Label("View Endpoints", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if imdsEndpointCount == 0, let onCreateIMDS {
                Button {
                    onCreateIMDS()
                } label: {
                    Label("Create Endpoint", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Create an app-managed IMDS endpoint for this profile.")
            }
        }
    }

    private var imdsSubtitle: String {
        if imdsEndpointCount > 0 {
            return "\(imdsEndpointCount) app-managed \(imdsEndpointCount == 1 ? "endpoint" : "endpoints") configured for this profile"
        }

        switch displayState {
        case .checking:
            return "Create an app-managed endpoint, then start it when credentials are available"
        case .signingIn:
            return "Create an endpoint definition while sign-in finishes"
        case .notSignedIn, .expired:
            return "Create an endpoint definition, then sign in before starting it"
        case .roleRejected:
            return "Create an endpoint definition after role access is restored"
        case .ready:
            return "Create an app-managed endpoint to serve these credentials locally"
        }
    }

    // MARK: - Credential fields

    private var unavailableCredentialMessage: String {
        switch displayState {
        case .checking:
            return "Checking status"
        case .signingIn:
            return "Waiting for sign-in"
        case .notSignedIn:
            return "Sign in required"
        case .expired:
            return "Expired"
        case .roleRejected:
            return "Unavailable"
        case .ready:
            return "Unavailable"
        }
    }

    private func loadingCredentialFields(text: String) -> some View {
        placeholderCredentialFields(message: text, showsProgress: true)
    }

    private func unavailableCredentialFields(message: String) -> some View {
        placeholderCredentialFields(message: message, showsProgress: false)
    }

    private func placeholderCredentialFields(message: String, showsProgress: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            placeholderCredentialRow("Access Key", message: message, showsProgress: showsProgress)
            rowDivider
            placeholderCredentialRow("Secret", message: message, showsProgress: false)
            rowDivider
            placeholderCredentialRow("Session Token", message: message, showsProgress: false)
            rowDivider
            sourceRow
        }
    }

    private func placeholderCredentialRow(
        _ label: String,
        message: String,
        showsProgress: Bool
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .trailing)

            HStack(spacing: 8) {
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(message)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder private func credentialFields(_ c: RoleCredentials) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            credentialRow("Access Key", value: c.accessKeyId, field: .accessKeyId, fingerprint: true)
            rowDivider
            credentialRow("Secret", value: c.secretAccessKey, field: .secretAccessKey, fingerprint: false)
            rowDivider
            credentialRow("Session Token", value: c.sessionToken, field: .sessionToken, fingerprint: false)
            rowDivider
            sourceRow
        }
    }

    @ViewBuilder private func credentialRow(
        _ label: String,
        value: String,
        field: Field,
        fingerprint: Bool
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .trailing)
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
    }

    private var sourceRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text("Source")
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .trailing)
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.cyan)
                    .frame(width: 7, height: 7)
                Text(sessionName)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(Color.cyan)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.cyan.opacity(0.18), in: Capsule())
        }
        .padding(.vertical, 10)
    }

    private var rowDivider: some View {
        Divider()
            .padding(.leading, 164)
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

    private func fetch(force: Bool = false, renew: Bool = false) async {
        // Terminal access-denied: a mint would just be re-rejected. Don't fire a doomed
        // Portal call — the roleRejected advisory (driven by the overlay) already explains
        // the state and offers no Retry (D31).
        if hasTerminalCredentialError { return }
        if !force && creds != nil { return }
        isFetching = true
        fetchError = nil
        defer { isFetching = false }
        do {
            let fetched = try await fetchCredentials(renew: renew)
            guard !Task.isCancelled else { return }
            creds = fetched
        } catch let e as IAMIdentityCenterError {
            guard !Task.isCancelled else { return }
            creds = nil
            fetchError = e
        } catch {
            guard !Task.isCancelled else { return }
            creds = nil
            fetchError = .network(error as? URLError ?? URLError(.unknown))
        }
    }

    private func fetchCredentials(renew: Bool) async throws -> RoleCredentials {
        if renew {
            return try await model.renewCredentials(
                forSession: sessionName,
                accountId: accountId,
                roleName: roleName,
                region: region
            )
        }

        return try await model.liveCredentials(
            forSession: sessionName,
            accountId: accountId,
            roleName: roleName,
            region: region
        )
    }

    private func resetCredentialStateForProfileChange() {
        creds = nil
        fetchError = nil
        revealed.removeAll()
    }

    // MARK: - Masking

    private func mask(_ value: String, fingerprint: Bool) -> String {
        guard fingerprint, value.count > 8 else {
            return String(repeating: "•", count: max(12, min(value.count, 24)))
        }
        return "\(value.prefix(4))••••••••\(value.suffix(4))"
    }

    private func remainingComponents(at date: Date) -> (hours: Int, minutes: Int) {
        let interval = max(0, expiresAt?.timeIntervalSince(date) ?? 0)
        let totalMinutes = Int(interval / 60)
        return (totalMinutes / 60, totalMinutes % 60)
    }

    private func remainingTextColor(at date: Date) -> Color {
        let interval = expiresAt?.timeIntervalSince(date) ?? 0
        if interval <= 0 { return .red }
        if interval < 30 * 60 { return .orange }
        return .primary
    }

    // MARK: - Clipboard

    private func credentialEnvironmentExports(for c: RoleCredentials) -> String {
        [
            "export AWS_ACCESS_KEY_ID=\(shellQuoted(c.accessKeyId))",
            "export AWS_SECRET_ACCESS_KEY=\(shellQuoted(c.secretAccessKey))",
            "export AWS_SESSION_TOKEN=\(shellQuoted(c.sessionToken))",
            "export AWS_REGION=\(shellQuoted(c.region))",
            "export AWS_DEFAULT_REGION=\(shellQuoted(c.region))"
        ].joined(separator: "\n")
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
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

#if DEBUG

private struct RevealPreviewHarness: View {
    let imdsEndpointCount: Int
    let seed: (CredentialsModel) -> Void
    @State private var model = CredentialsModel(service: PreviewIdentityCenterService())

    init(
        imdsEndpointCount: Int = 1,
        seed: @escaping (CredentialsModel) -> Void
    ) {
        self.imdsEndpointCount = imdsEndpointCount
        self.seed = seed
    }

    var body: some View {
        DetailCard("Credentials") {
            CredentialsRevealSection(
                profileName: "ac:cp:org_admin",
                sessionName: "acme",
                accountId: "123456789012",
                roleName: "AdministratorAccess",
                region: "us-east-1",
                imdsEndpointCount: imdsEndpointCount,
                onSignIn: {},
                onViewIMDS: {},
                onCreateIMDS: {},
                onViewSession: {}
            )
            .environment(model)
        }
        .frame(width: 760)
        .task {
            seed(model)
        }
    }
}

#Preview("ready") {
    RevealPreviewHarness { m in
        m.seedProfileStatusForTesting(.ready(expiresAt: Date().addingTimeInterval(3000)),
                                      key: "acme:123456789012:AdministratorAccess")
    }
}

#Preview("ready + no endpoint") {
    RevealPreviewHarness(imdsEndpointCount: 0) { m in
        m.seedProfileStatusForTesting(.ready(expiresAt: Date().addingTimeInterval(3000)),
                                      key: "acme:123456789012:AdministratorAccess")
    }
}

#Preview("ready + multiple endpoints") {
    RevealPreviewHarness(imdsEndpointCount: 2) { m in
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

#Preview("signing in – expired code") {
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
                    expiresAt: Date().addingTimeInterval(-60),
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

#endif
