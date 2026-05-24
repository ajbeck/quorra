import SwiftUI

/// The credential-source tag shown as a profile row's secondary line.
///
/// SSO profiles pass a deterministic per-session hue (`Theme.sessionBadgeColor(for:)`);
/// long-term and "other" profiles pass `nil` to render the neutral style. Color carries
/// one meaning only — *which SSO org* — so it never competes with the status vocabulary
/// (green/red/secondary) owned by `ProfileStatusIcon`.
struct ViaBadge: View {
    let label: String
    /// Per-session hue for SSO profiles; `nil` renders the neutral (long-term / other) style.
    var color: Color? = nil

    var body: some View {
        let tint = color ?? .secondary
        HStack(spacing: 4) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
            Text(label)
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.16), in: Capsule())
    }
}

// MARK: - Previews

#Preview("ViaBadge – light") {
    ViaBadgeGallery()
        .padding()
        .frame(width: 220, alignment: .leading)
}

#Preview("ViaBadge – dark") {
    ViaBadgeGallery()
        .padding()
        .frame(width: 220, alignment: .leading)
        .preferredColorScheme(.dark)
}

private struct ViaBadgeGallery: View {
    private let sessions = ["acme", "blueriver", "globex", "initech", "umbrella", "wayne"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(sessions, id: \.self) { name in
                ViaBadge(label: name, color: Theme.sessionBadgeColor(for: name))
            }
            ViaBadge(label: "long-term")
            ViaBadge(label: "other")
        }
    }
}
