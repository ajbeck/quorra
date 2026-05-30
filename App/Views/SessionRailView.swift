import SwiftUI
import IAMIdentityCenter

struct SessionRailView: View {
    @Binding var filter: SessionFilter
    @Environment(ProfilesModel.self) private var profilesModel

    var body: some View {
        switch profilesModel.loadState {
        case .idle, .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView(
                "Failed to Load Sessions",
                systemImage: "exclamationmark.triangle",
                description: Text("Quorra couldn't read your AWS configuration.")
            )
        case .loaded:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("SSO Sessions")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text("\(sortedSessions.count)")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .textCase(.uppercase)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)

                    sessionButton(
                        for: .all,
                        title: "All Sessions",
                        systemImage: "square.grid.2x2",
                        count: allProfileCount,
                        isAllSessions: true
                    )

                    ForEach(sortedSessions) { session in
                        sessionButton(
                            for: .session(name: session.id),
                            title: session.id,
                            systemImage: "cloud",
                            count: session.profiles.count,
                            isAllSessions: false
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
        }
    }

    private func sessionButton(
        for candidate: SessionFilter,
        title: String,
        systemImage: String,
        count: Int,
        isAllSessions: Bool
    ) -> some View {
        Button {
            filter = candidate
        } label: {
            SessionRailRow(
                title: title,
                systemImage: systemImage,
                count: count,
                isAllSessions: isAllSessions
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(rowBackground(isSelected: filter == candidate), in: RoundedRectangle(cornerRadius: 6))
    }

    private func rowBackground(isSelected: Bool) -> Color {
        isSelected ? Color.accentColor.opacity(0.18) : Color.clear
    }

    private var sortedSessions: [SSOSessionNode] {
        profilesModel.groups.ssoSessions.sorted {
            $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }

    private var allProfileCount: Int {
        profilesModel.groups.flatProfiles.count
    }
}

private struct SessionRailRow: View {
    let title: String
    let systemImage: String
    let count: Int
    let isAllSessions: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .symbolRenderingMode(isAllSessions ? .monochrome : .hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)

            Text(title)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text("\(count)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .accessibilityLabel("\(count) profiles")
        }
        .padding(.vertical, 2)
    }
}

#Preview("SessionRail – populated") {
    SessionRailPreviewHarness()
}

private struct SessionRailPreviewHarness: View {
    @State private var filter: SessionFilter = .all
    @State private var profilesModel = ProfilesModel.previewLoaded(
        config: PreviewAWSFixtures.mockupConfig,
        credentials: PreviewAWSFixtures.mockupCredentials
    )

    var body: some View {
        NavigationSplitView {
            SessionRailView(filter: $filter)
        } detail: {
            Text("Detail")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(profilesModel)
        .frame(width: 700, height: 500)
    }
}
