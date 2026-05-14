import SwiftUI
import IAMIdentityCenter
import AppKit

/// Four-state inline sign-in panel for SSO sessions.
///
/// Branches on the passed-in state in priority order:
/// 1. in-flight — user code + progress + cancel
/// 2. error — error message + retry
/// 3. signed in — success badge + countdown timer + "Sign in again"
/// 4. idle — sign-in button (or missing-field warning)
struct SignInPanel: View {
    let sessionName: String
    let startUrl: URL?
    let region: String?
    let scopes: [String]?
    let progress: SignInProgress?
    let error: IAMIdentityCenterError?
    let signedInToken: StoredSSOToken?
    let isReadOnly: Bool
    let onSignIn: () -> Void
    let onCancel: () -> Void

    var body: some View {
        if let progress = progress {
            inFlightView(progress: progress)
        } else if let error = error {
            errorView(error: error)
        } else if let signedInToken = signedInToken {
            signedInView(token: signedInToken)
        } else {
            idleView
        }
    }
    
    @ViewBuilder
    private var idleView: some View {
        if let missingField = firstMissingRequiredField {
            Text("Missing required field: \(missingField)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Button("Sign in with IAM Identity Center") {
                onSignIn()
            }
            .disabled(isReadOnly)
        }
    }
    
    @ViewBuilder
    private func inFlightView(progress: SignInProgress) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("User code") {
                Text(progress.userCode)
                    .font(.system(.title3, design: .monospaced, weight: .semibold))
                    .textSelection(.enabled)
            }
            
            Link("Open browser again", destination: progress.verificationUriComplete)
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
    
    @ViewBuilder
    private func errorView(error: IAMIdentityCenterError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let description = error.errorDescription {
                Text(description)
                    .foregroundStyle(.red)
            }
            
            if let suggestion = error.recoverySuggestion {
                Text(suggestion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Button("Try again") {
                onSignIn()
            }
            .controlSize(.small)
            .disabled(isReadOnly)
        }
    }
    
    @ViewBuilder
    private func signedInView(token: StoredSSOToken) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Signed in.").font(.callout.weight(.semibold))
                HStack(spacing: 4) {
                    Text("Token expires in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // Apple: SwiftUI/Text/init(timerInterval:pauseTime:countsDown:showsHours:)
                    Text(timerInterval: Date.now...token.expiresAt, countsDown: true)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button("Sign in again") { onSignIn() }
                .controlSize(.small)
                .disabled(isReadOnly)
        }
    }

    private var firstMissingRequiredField: String? {
        if startUrl == nil {
            return "sso_start_url"
        }
        if region == nil {
            return "sso_region"
        }
        return nil
    }
}
