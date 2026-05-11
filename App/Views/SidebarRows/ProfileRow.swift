import SwiftUI
import AWSConfigINI

struct ProfileRow: View {
    let profile: ProfileNode

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.secondary)
            Text(profile.id)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityLabel("Profile \(profile.id), region \(profile.profile.region ?? "unset")")
    }
}

#Preview("ProfileRow – with region") {
    let node = ProfileNode(id: "acme-prod-admin", profile: .init(region: "us-east-1"), origin: .configOnly)
    ProfileRow(profile: node)
        .padding()
}

#Preview("ProfileRow – no region") {
    let node = ProfileNode(id: "default", profile: .init(), origin: .both)
    ProfileRow(profile: node)
        .padding()
}
