import SwiftUI
import IAMIdentityCenter
import QuorraAppLogic

/// Inline sign-in panel for SSO sessions.
///
/// Branches on `SessionAuthStatus` into three view modes per D8:
/// - `needsAction`: signedOut / expired(canRefresh: false) — Sign in button
///   (+ expired caption / sign-out server-side advisory when applicable)
/// - `inProgress`: signingIn — user code + countdown + Cancel
/// - `ready`: signedIn / expired(canRefresh: true) — success badge + countdown + [Sign out] [Sign in again]
///
/// **A2 (D16/D17):** `ready` mode gains two optional sections driven by the A2 overlay flags:
/// - `isRefreshing: true` — subtle "Refreshing…" caption
/// - `hasRefreshFailure: true` — advisory "Couldn't refresh your session. [Refresh now]" + Refresh now button
/// - `canRefresh: false` in `signedIn` — caption "Token will expire at HH:mm — sign in again to keep working"
///
/// `lastError` and `signOutFailed` overlay the appropriate mode with additional context.
struct SignInPanel: View {
    let sessionName: String
    let startUrl: URL?
    let region: String?
    let scopes: [String]?
    let authStatus: SessionAuthStatus
    let progress: SignInProgress?
    let lastError: IAMIdentityCenterError?
    let signOutFailed: Bool
    let isReadOnly: Bool
    /// A2: true when `CredentialsModel.refreshingNow.contains(sessionName)` (D17)
    var isRefreshing: Bool = false
    /// A2: true when `CredentialsModel.refreshFailure.contains(sessionName)` (D16)
    var hasRefreshFailure: Bool = false
    let onSignIn: () -> Void
    let onCancel: () -> Void
    let onSignOut: () -> Void
    /// A2: invoked when the user taps "Refresh now" in the transient-failure advisory (D16)
    var onRefreshNow: (() -> Void)? = nil
    @Environment(\.authBrowserPresenter) private var authBrowserPresenter

    var body: some View {
        switch authStatus {
        case .signingIn:
            if let progress = progress {
                inProgressView(progress: progress)
            } else {
                // Transitioning — inFlight not yet populated
                ProgressView()
                    .controlSize(.small)
            }

        case .signedIn(let expiresAt, _), .expired(let expiresAt, canRefresh: true):
            readyView(expiresAt: expiresAt)

        case .signedOut, .expired(_, canRefresh: false):
            needsActionView
        }
    }

    // MARK: - needsAction mode

    @ViewBuilder
    private var needsActionView: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Sign-out server-side failure advisory (D7)
            if signOutFailed {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text("Local sign-out succeeded, but Quorra couldn't notify AWS. Your token will expire naturally within 8 hours.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Expired token caption
            if case .expired(_, canRefresh: false) = authStatus {
                Text("Token expired.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Last sign-in error
            if let error = lastError {
                VStack(alignment: .leading, spacing: 4) {
                    if let description = error.errorDescription {
                        Text(description)
                            .foregroundStyle(.red)
                    }
                    if let suggestion = error.recoverySuggestion {
                        Text(suggestion)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let missingField = firstMissingRequiredField {
                Text("Missing required field: \(missingField)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button(lastError != nil ? "Try again" : "Sign in with IAM Identity Center") {
                    onSignIn()
                }
                .disabled(isReadOnly)
            }
        }
    }

    // MARK: - inProgress mode

    @ViewBuilder
    private func inProgressView(progress: SignInProgress) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("User code") {
                Text(progress.userCode)
                    .font(.system(.title3, design: .monospaced, weight: .semibold))
                    .textSelection(.enabled)
            }

            Button("Open browser again") {
                authBrowserPresenter.present(progress.verificationUriComplete)
            }
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for browser sign-in…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Text("Expires in:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // Apple: SwiftUI/Text/init(timerInterval:pauseTime:countsDown:showsHours:)
                    Text(timerInterval: Date.now...progress.expiresAt, countsDown: true)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Button("Cancel", role: .cancel) {
                onCancel()
            }
            .controlSize(.small)
            .disabled(isReadOnly)
        }
    }

    // MARK: - ready mode

    @ViewBuilder
    private func readyView(expiresAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Signed in.").font(.callout.weight(.semibold))
                    // A2 D17: refreshing caption
                    if isRefreshing {
                        Text("Refreshing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if case .signedIn(_, canRefresh: false) = authStatus {
                        // D16: canRefresh: false caption — no refresh token, expiry is final
                        Text("Token will expire at \(expiresAt, format: .dateTime.hour().minute()) — sign in again to keep working.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 4) {
                            Text("Token expires in")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            // Apple: SwiftUI/Text/init(timerInterval:pauseTime:countsDown:showsHours:)
                            Text(timerInterval: Date.now...expiresAt, countsDown: true)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
                // D5: Sign out first (no confirmation needed — deletes refreshable credential, not user data)
                Button("Sign out") {
                    onSignOut()
                }
                .controlSize(.small)
                // Read-only mode permits sign-out per D5 — auth state is orthogonal to file-write gating
                Button("Sign in again") {
                    onSignIn()
                }
                .controlSize(.small)
                .disabled(isReadOnly)
            }

            // A2 D16: transient refresh-failure advisory with [Refresh now] button.
            // Only shown when hasRefreshFailure is true (set by CredentialsModel on .refreshFailed
            // for transient errors; cleared by .refreshed / new .signedIn / .signedOut).
            // HIG Identity → SSO: surface controls only when intervention is required.
            if hasRefreshFailure {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Couldn't refresh your session.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let onRefreshNow {
                            Button("Refresh now") {
                                onRefreshNow()
                            }
                            .controlSize(.small)
                            .accessibilityLabel("Refresh session token now")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var firstMissingRequiredField: String? {
        if startUrl == nil { return "sso_start_url" }
        if region == nil { return "sso_region" }
        return nil
    }
}
