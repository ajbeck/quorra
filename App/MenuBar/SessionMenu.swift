import IAMIdentityCenter
import QuorraAppLogic
import SwiftUI

/// One IAM Identity Center session in the menu bar: its sign-in state in the title, its
/// actions in a submenu.
struct SessionMenu: View {
    let sessionName: String
    let status: SessionAuthStatus
    let runtimeCoordinator: AppRuntimeCoordinator
    let credentialsModel: CredentialsModel
    let showInQuorra: (DetailSelection) -> Void

    var body: some View {
        Menu {
            Text(statusLine)

            switch status {
            case .signedIn(_, let canRefresh):
                if canRefresh {
                    Button("Refresh") {
                        Task { await credentialsModel.refreshNow(sessionName: sessionName) }
                    }
                }
            case .signingIn:
                Button("Open Sign-In Page") {
                    runtimeCoordinator.openAuthenticationPage(for: sessionName)
                }
            case .signedOut, .expired:
                Button("Sign In…") {
                    runtimeCoordinator.signIn(to: sessionName)
                }
            }

            Divider()

            Button("Show in Quorra…") {
                showInQuorra(.session(name: sessionName))
            }
        } label: {
            Label(menuTitle(sessionName), systemImage: statusImage)
                .labelStyle(.titleAndIcon)
        }
        .accessibilityLabel("\(sessionName), \(statusLine)")
    }

    private var statusLine: String {
        switch status {
        case .signedIn(let expiresAt, _):
            return "Signed in until \(expiresAt.formatted(date: .omitted, time: .shortened))"
        case .expired:
            return "Expired"
        case .signingIn:
            return "Signing in…"
        case .signedOut:
            return "Signed out"
        }
    }

    private var statusImage: String {
        switch status {
        case .signedIn:
            return "circle.fill"
        case .signingIn:
            return "circle.dotted"
        case .expired(_, let canRefresh):
            return canRefresh ? "circle" : "exclamationmark.triangle.fill"
        case .signedOut:
            return "circle"
        }
    }
}
