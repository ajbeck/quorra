import AppKit
import SwiftUI

struct IMDSSystemExtensionGuidance: View {
    let status: IMDSSystemExtensionStatus

    var body: some View {
        switch status {
        case .awaitingApproval:
            guidance(
                message: "Approve Quorra’s system extension in System Settings under General → Login Items & Extensions. Quorra will continue automatically after approval.",
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
                Button("Open System Settings") {
                    NSWorkspace.shared.open(
                        URL(filePath: "/System/Applications/System Settings.app")
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .font(.callout)
    }
}
