import ServiceManagement
import SwiftUI

struct IMDSSystemExtensionGuidance: View {
    let status: IMDSSystemExtensionStatus

    var body: some View {
        switch status {
        case .awaitingApproval:
            guidance(
                message: "macOS is waiting for Quorra’s Network Extension to be enabled. In Login Items & Extensions, click the info button beside Quorra under Extensions, then turn on its Network Extension. Quorra will continue automatically.",
                systemImage: "exclamationmark.shield.fill",
                color: .orange,
                showsSettingsButton: true
            )
        case .restartRequired:
            guidance(
                message: "Restart this Mac to finish activating Quorra’s system extension.",
                systemImage: "restart.circle.fill",
                color: .orange
            )
        case .failed(let message):
            guidance(
                message: message,
                systemImage: "exclamationmark.triangle.fill",
                color: .red,
                showsSettingsButton: message.contains("System Settings")
            )
        case .notRequested, .activating, .activated:
            EmptyView()
        }
    }

    private func guidance(
        message: String,
        systemImage: String,
        color: Color,
        showsSettingsButton: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Label(message, systemImage: systemImage)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if showsSettingsButton {
                Button("Open Login Items & Extensions") {
                    SMAppService.openSystemSettingsLoginItems()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .font(.callout)
    }
}
