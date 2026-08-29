import SwiftUI
import AWSConfigINI
import IAMIdentityCenter
import QuorraAppLogic

/// A session row in the SSO Sessions list. Two lines: status icon + name + live
/// expiry tag (line 1), and "N profiles · region" (line 2). Reuses the shipped
/// `SessionStatusIcon` vocabulary — the icon owns the status color, so the expiry
/// tag stays neutral.
struct SessionRow: View {
    let session: SSOSessionNode
    let authStatus: SessionAuthStatus
    var isRefreshing: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            SessionStatusIcon(
                authStatus: authStatus,
                isRefreshing: isRefreshing
            )
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.id)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    expiryTag
                }
                Text(secondLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Live expiry tag. `TimelineView(.everyMinute)` re-renders the text each minute so
    /// the "Xh Ym left" countdown stays current without a manual timer.
    @ViewBuilder private var expiryTag: some View {
        TimelineView(.everyMinute) { _ in
            Text(expiryText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private var expiryText: String {
        switch authStatus {
        case .signedIn(let expiresAt, _):
            let remaining = expiresAt.timeIntervalSinceNow
            guard remaining > 0 else { return "expiring" }
            let formatted = Duration.seconds(remaining).formatted(
                .units(allowed: [.hours, .minutes], width: .narrow, maximumUnitCount: 2)
            )
            return "\(formatted) left"
        case .expired(let expiredAt, _):
            return "expired \(expiredAt.formatted(.relative(presentation: .named)))"
        case .signingIn:
            return "Signing in…"
        case .signedOut:
            return "Signed out"
        }
    }

    private var secondLine: String {
        let count = session.profiles.count
        let profilePart = "\(count) profile\(count == 1 ? "" : "s")"
        if let region = session.session?.ssoRegion, !region.isEmpty {
            return "\(profilePart) · \(region)"
        }
        return profilePart
    }

    private var accessibilityLabel: String {
        let count = session.profiles.count
        let profilePart = "\(count) profile\(count == 1 ? "" : "s")"
        return "SSO session \(session.id), \(authStatus.accessibilityPhrase), \(profilePart)"
    }
}

// MARK: - Previews

#if DEBUG

#Preview("SessionRow – light") {
    SessionRowGallery()
}

#Preview("SessionRow – dark") {
    SessionRowGallery()
        .preferredColorScheme(.dark)
}

/// Renders the session row across its statuses. Like `ProfileRow`, it deliberately avoids
/// a `.sidebar` `List` (the row preview stays focused on the row; list chrome is
/// validated by the `SourceSidebarView` preview) and seeds statuses in `init` so the first frame
/// is final — no async mutation mid-layout.
private struct SessionRowGallery: View {
    private func node(_ id: String, region: String?, profiles: Int) -> SSOSessionNode {
        SSOSessionNode(
            id: id,
            session: SSOSession(ssoStartUrl: "https://\(id).awsapps.com/start", ssoRegion: region, ssoRegistrationScopes: nil),
            profiles: (0..<profiles).map { ProfileNode(id: "\(id)-\($0)", profile: .init(), origin: .configOnly) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SessionRow(
                session: node("acme", region: "us-east-1", profiles: 4),
                authStatus: .signedIn(expiresAt: Date().addingTimeInterval(6 * 3600 + 12 * 60), canRefresh: true)
            )
            SessionRow(
                session: node("blueriver", region: "eu-west-1", profiles: 1),
                authStatus: .expired(expiredAt: Date().addingTimeInterval(-2 * 86400), canRefresh: false)
            )
            SessionRow(
                session: node("globex", region: "us-west-2", profiles: 0),
                authStatus: .signingIn
            )
            SessionRow(session: node("initech", region: nil, profiles: 2), authStatus: .signedOut)
        }
        .padding(.vertical, 4)
        .frame(width: 260)
    }
}

#endif
