import SwiftUI
import IAMIdentityCenter
import AppKit

/// Three-state inline sign-in panel for SSO sessions.
///
/// Branches on the passed-in state (idle, in-flight, or error) and renders the appropriate UI:
/// idle shows the sign-in button, in-flight shows the user code + progress + cancel, error shows
/// the error message + retry.
struct SignInPanel: View {
    let sessionName: String
    let startUrl: URL?
    let region: String?
    let scopes: [String]?
    let progress: SignInProgress?
    let error: IAMIdentityCenterError?
    let isReadOnly: Bool
    let onSignIn: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    
    var body: some View {
        if let progress = progress {
            inFlightView(progress: progress)
        } else if let error = error {
            errorView(error: error)
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
                onRetry()
            }
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
