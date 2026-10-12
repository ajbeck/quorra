import SwiftUI
import DatabaseProxy
import QuorraAppLogic

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
                    Text(session.name)
                        .lineLimit(1)
                    Text("\(session.profileCount) \(session.profileCount == 1 ? "profile" : "profiles")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .padding(.vertical, 3)

        case .profile(let profile):
            HStack(spacing: 8) {
                Image(systemName: "key")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 5) {
                    Text(profile.name)
                        .lineLimit(1)
                    ViaBadge(
                        label: profile.sessionName ?? "no session",
                        color: profile.sessionName.map { Theme.sessionBadgeColor(for: $0) }
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

        case .clientVPN(let vpn):
            HStack(spacing: 8) {
                Image(systemName: vpn.status.systemImage)
                    .foregroundStyle(vpn.status.tint)
                    .frame(width: 18)
                    .accessibilityLabel(vpn.status.title)
                VStack(alignment: .leading, spacing: 3) {
                    Text(vpn.name)
                        .lineLimit(1)
                    Text(vpn.status.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .padding(.vertical, 3)

        case .databaseConnection(let connection):
            HStack(spacing: 8) {
                Image(systemName: connection.state.systemImage)
                    .foregroundStyle(connection.state.tint)
                    .frame(width: 18)
                    .accessibilityLabel(connection.state.rawValue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(connection.name)
                        .lineLimit(1)
                    Text(connection.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(verbatim: ":\(connection.localPort)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)

        case .databaseCredential(let credential):
            HStack(spacing: 8) {
                Image(systemName: "person.badge.key")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(credential.name)
                        .lineLimit(1)
                    Text("\(credential.username) · \(credential.connectionCount) \(credential.connectionCount == 1 ? "connection" : "connections")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
