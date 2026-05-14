import SwiftUI
import AWSConfigINI
import IAMIdentityCenter

struct SessionRow: View {
    let session: SSOSessionNode
    @Environment(CredentialsModel.self) private var credentialsModel

    private var authStatus: SessionAuthStatus {
        credentialsModel.status[session.id] ?? .signedOut
    }

    var body: some View {
        HStack(spacing: 8) {
            // SessionStatusIcon is accessibility-hidden; the row label carries the phrase.
            // D17: isRefreshing drives the pulse overlay independently of auth status.
            SessionStatusIcon(
                authStatus: authStatus,
                isRefreshing: credentialsModel.refreshingNow.contains(session.id)
            )
            Text(session.id)
                .lineLimit(1)
            Spacer(minLength: 0)
            if session.profiles.count > 0 {
                Text("\(session.profiles.count)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        // Apple: SwiftUI/View/task(id:name:priority:file:line:_:) — cancels on disappear,
        // restarts when session.id changes. Populates the status cache on first appearance.
        .task(id: session.id) {
            await credentialsModel.observeStatus(forSession: session.id)
        }
    }

    private var accessibilityLabel: String {
        let profileCount = session.profiles.count
        let profilePart = "\(profileCount) profile\(profileCount == 1 ? "" : "s")"
        return "SSO session \(session.id), \(authStatus.accessibilityPhrase), \(profilePart)"
    }
}

// MARK: - Previews

#Preview("SessionRow – signed in, with profiles") {
    let node = SSOSessionNode(id: "acme", session: nil, profiles: [
        ProfileNode(id: "acme-prod-admin", profile: .init(), origin: .configOnly),
        ProfileNode(id: "acme-prod-readonly", profile: .init(), origin: .configOnly),
    ])
    let model = CredentialsModel(service: PreviewIdentityCenterService())
    SessionRow(session: node)
        .environment(model)
        .task {
            model.seedStatusForTesting(.signedIn(expiresAt: Date().addingTimeInterval(3600), canRefresh: false), sessionName: "acme")
        }
        .padding()
}

#Preview("SessionRow – signed out") {
    let node = SSOSessionNode(id: "blueriver", session: nil, profiles: [])
    let model = CredentialsModel(service: PreviewIdentityCenterService())
    SessionRow(session: node)
        .environment(model)
        .padding()
}

#Preview("SessionRow – expired, needs sign in") {
    let node = SSOSessionNode(id: "expired-corp", session: nil, profiles: [])
    let model = CredentialsModel(service: PreviewIdentityCenterService())
    SessionRow(session: node)
        .environment(model)
        .task {
            model.seedStatusForTesting(
                .expired(expiredAt: Date().addingTimeInterval(-60), canRefresh: false),
                sessionName: "expired-corp"
            )
        }
        .padding()
}

#Preview("SessionRow – signing in") {
    let node = SSOSessionNode(id: "signing-session", session: nil, profiles: [])
    let model = CredentialsModel(service: PreviewIdentityCenterService())
    SessionRow(session: node)
        .environment(model)
        .task {
            model.seedStatusForTesting(.signingIn, sessionName: "signing-session")
        }
        .padding()
}

#Preview("SessionRow – refreshing overlay") {
    let node = SSOSessionNode(id: "refresh-session", session: nil, profiles: [])
    let model = CredentialsModel(service: PreviewIdentityCenterService())
    SessionRow(session: node)
        .environment(model)
        .task {
            model.seedStatusForTesting(
                .signedIn(expiresAt: Date().addingTimeInterval(3600), canRefresh: true),
                sessionName: "refresh-session"
            )
            model.seedRefreshingNowForTesting(sessionName: "refresh-session")
        }
        .padding()
}
