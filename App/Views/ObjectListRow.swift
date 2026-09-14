import SwiftUI
import QuorraProfiles

struct ObjectListRow: View {
    let item: ObjectListItem

    var body: some View {
        switch item {
        case .session(let session):
            HStack(spacing: 8) {
                Image(systemName: "cloud")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.id)
                        .lineLimit(1)
                    Text("\(session.profiles.count) \(session.profiles.count == 1 ? "profile" : "profiles")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .padding(.vertical, 3)

        case .profile(let profile):
            HStack(spacing: 8) {
                Image(systemName: profile.via.isSSO ? "key" : "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 5) {
                    Text(profile.id)
                        .lineLimit(1)
                    ViaBadge(
                        label: profile.via.label,
                        color: profile.via.badgeColor
                    )
                }
                Spacer(minLength: 8)
            }
            .padding(.vertical, 3)

        case .imds(let endpoint):
            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(endpoint.state.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Text(endpoint.title)
                            .fontDesign(endpoint.isDefault ? .default : .monospaced)
                            .fontWeight(endpoint.isDefault ? .semibold : .regular)
                            .lineLimit(1)
                        if endpoint.isDefault {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help("Built-in endpoint; it can’t be deleted")
                        }
                    }
                    HStack(spacing: 6) {
                        IMDSBadge(state: endpoint.state)
                        Text(endpoint.profileName.isEmpty ? "Choose a profile" : endpoint.profileName)
                            .font(.caption)
                            .foregroundStyle(endpoint.profileName.isEmpty ? Color.orange : Color.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.vertical, 3)
        }
    }
}

private struct IMDSBadge: View {
    let state: IMDSEndpointState

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(state.accent)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(state.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(state.accent.opacity(0.16), in: Capsule())
    }

    private var text: String {
        switch state {
        case .inactive:
            return "off"
        case .starting:
            return "starting"
        case .active:
            return "live"
        case .failed:
            return "failed"
        }
    }
}

private extension ProfileVia {
    var badgeColor: Color? {
        switch self {
        case .session(let name):
            return Theme.sessionBadgeColor(for: name)
        case .longTerm, .other:
            return nil
        }
    }
}

private extension IMDSEndpointState {
    var accent: Color {
        switch self {
        case .inactive:
            return .secondary
        case .starting:
            return .blue
        case .active:
            return .green
        case .failed:
            return .orange
        }
    }
}
