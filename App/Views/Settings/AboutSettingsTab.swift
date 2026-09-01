import AppKit
import QuorraAppLogic
import SwiftUI

struct AppBuildInfo: Equatable, Sendable {
    let version: String
    let build: String

    static var current: AppBuildInfo {
        AppBuildInfo(
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—",
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        )
    }

    var displayValue: String {
        "Version \(version) (build \(build))"
    }
}

struct AboutSettingsTab: View {
    typealias UpdateCheck = @Sendable (ReleaseVersion) async throws -> AppUpdateAvailability

    private let buildInfo: AppBuildInfo
    private let checkForUpdates: UpdateCheck
    @State private var updateState = UpdateState.idle

    init(
        buildInfo: AppBuildInfo = .current,
        checkForUpdates: @escaping UpdateCheck = { currentVersion in
            let checker = try GitHubReleaseChecker(owner: "ajbeck", repository: "quorra")
            return try await checker.check(currentVersion: currentVersion)
        }
    ) {
        self.buildInfo = buildInfo
        self.checkForUpdates = checkForUpdates
    }

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)

            Image(systemName: "circle.hexagongrid.circle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)

            Text("Quorra")
                .font(.system(size: 18, weight: .semibold))

            Text(buildInfo.displayValue)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            updateStatusCard
                .padding(.top, 12)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .navigationTitle("About")
        .task {
            guard updateState == .idle else { return }
            await performUpdateCheck()
        }
    }

    private var updateStatusCard: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.callout.weight(.medium))
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)
            statusAction
        }
        .padding(12)
        .frame(maxWidth: 420, minHeight: 64)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch updateState {
        case .checking:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Checking for updates")
        case .available:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
        case .upToDate:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
        case .developmentBuild:
            Image(systemName: "hammer.circle.fill")
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warn)
                .accessibilityHidden(true)
        case .idle:
            Image(systemName: "arrow.triangle.2.circlepath.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var statusTitle: String {
        switch updateState {
        case .idle:
            return "Check for updates"
        case .checking:
            return "Checking for updates…"
        case .available(let release):
            return "Version \(release.version) is available"
        case .upToDate:
            return "Quorra is up to date"
        case .developmentBuild:
            return "This is a newer build"
        case .failed:
            return "Couldn’t check for updates"
        }
    }

    private var statusDetail: String {
        switch updateState {
        case .idle:
            return "Compare this build with the latest GitHub release."
        case .checking:
            return "Looking for the latest stable release on GitHub."
        case .available(let release):
            return release.diskImageURL == nil
                ? "View the release on GitHub to download it."
                : "The release disk image is ready to download."
        case .upToDate(let release):
            return "Latest release: \(release.tagName)."
        case .developmentBuild(let release):
            return "Latest public release: \(release.tagName)."
        case .failed:
            return "Check your connection and try again."
        }
    }

    @ViewBuilder
    private var statusAction: some View {
        switch updateState {
        case .idle:
            Button("Check Now") {
                Task { await performUpdateCheck() }
            }
            .controlSize(.small)
        case .checking:
            EmptyView()
        case .available(let release):
            Button(release.diskImageURL == nil ? "View Release…" : "Download Update…") {
                NSWorkspace.shared.open(release.diskImageURL ?? release.releaseURL)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.small)
        case .upToDate, .developmentBuild:
            Button("Check Again") {
                Task { await performUpdateCheck() }
            }
            .controlSize(.small)
        case .failed:
            Button("Try Again") {
                Task { await performUpdateCheck() }
            }
            .controlSize(.small)
        }
    }

    private func performUpdateCheck() async {
        guard let currentVersion = ReleaseVersion(buildInfo.version) else {
            updateState = .failed
            return
        }

        updateState = .checking
        do {
            switch try await checkForUpdates(currentVersion) {
            case .updateAvailable(let release):
                updateState = .available(release)
            case .upToDate(let release):
                updateState = .upToDate(release)
            case .developmentBuild(let release):
                updateState = .developmentBuild(release)
            }
        } catch is CancellationError {
            updateState = .idle
        } catch {
            if Task.isCancelled {
                updateState = .idle
            } else {
                updateState = .failed
            }
        }
    }
}

private enum UpdateState: Equatable {
    case idle
    case checking
    case available(GitHubRelease)
    case upToDate(GitHubRelease)
    case developmentBuild(GitHubRelease)
    case failed
}

#if DEBUG

private let previewRelease = GitHubRelease(
    version: ReleaseVersion("0.2.0")!,
    tagName: "v0.2.0",
    releaseURL: URL(string: "https://github.com/ajbeck/quorra/releases/tag/v0.2.0")!,
    diskImageURL: URL(string: "https://github.com/ajbeck/quorra/releases/download/v0.2.0/Quorra-0.2.0.dmg")!
)

#Preview("About – update available") {
    AboutSettingsTab(
        buildInfo: AppBuildInfo(version: "0.1.2", build: "218"),
        checkForUpdates: { _ in .updateAvailable(previewRelease) }
    )
    .frame(width: 540, height: 360)
}

#Preview("About – up to date") {
    AboutSettingsTab(
        buildInfo: AppBuildInfo(version: "0.2.0", build: "241"),
        checkForUpdates: { _ in .upToDate(previewRelease) }
    )
    .frame(width: 540, height: 360)
}

#Preview("About – unavailable") {
    AboutSettingsTab(
        buildInfo: AppBuildInfo(version: "0.1.2", build: "218"),
        checkForUpdates: { _ in throw URLError(.notConnectedToInternet) }
    )
    .frame(width: 540, height: 360)
}

#endif
