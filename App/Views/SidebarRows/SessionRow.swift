import SwiftUI
import AWSConfigINI

struct SessionRow: View {
    let session: SSOSessionNode

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.icloud")
                .foregroundStyle(.secondary)
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
        .accessibilityLabel("SSO session \(session.id), \(session.profiles.count) profile(s)")
    }
}

#Preview("SessionRow – with profiles") {
    let node = SSOSessionNode(id: "acme", session: nil, profiles: [
        ProfileNode(id: "acme-prod-admin", profile: .init(), origin: .configOnly),
        ProfileNode(id: "acme-prod-readonly", profile: .init(), origin: .configOnly),
    ])
    SessionRow(session: node)
        .padding()
}

#Preview("SessionRow – no profiles") {
    let node = SSOSessionNode(id: "blueriver", session: nil, profiles: [])
    SessionRow(session: node)
        .padding()
}
