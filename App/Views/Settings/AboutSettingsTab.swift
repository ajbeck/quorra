import SwiftUI

struct AboutSettingsTab: View {
    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "Version \(version) (build \(build))"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "circle.hexagongrid.circle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)

            Text("Quorra")
                .font(.system(size: 18, weight: .semibold))

            Text(versionString)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .navigationTitle("About")
    }
}

#Preview {
    AboutSettingsTab()
        .frame(width: 540, height: 320)
}
