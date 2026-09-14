import QuorraAppLogic
import SwiftUI

struct IMDSSettingsTab: View {
    @Environment(AppRuntimeCoordinator.self) private var runtimeCoordinator
    @Environment(IMDSProxyController.self) private var imdsProxyController

    var body: some View {
        Form {
            Section("Default endpoint") {
                Toggle(
                    "Use the standard EC2 metadata address",
                    isOn: Binding(
                        get: { runtimeCoordinator.isDefaultEndpointEnabled },
                        set: { shouldInstall in
                            Task { await runtimeCoordinator.setDefaultEndpointEnabled(shouldInstall) }
                        }
                    )
                )
                .disabled(imdsProxyController.isChangingInstallation)

                LabeledContent("Address") {
                    Text("169.254.169.254:80")
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }

                Text("Quorra routes only TCP connections for this address through its Network Extension. The extension relays opaque bytes to Quorra’s local IMDSv2 server and never interprets, stores, or logs credentials or tokens.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("System integration") {
                IMDSIntegrationStatusPath(
                    extensionStatus: imdsProxyController.systemExtensionStatus,
                    routingStatus: imdsProxyController.connectionStatus
                )

                Text("The system extension remains installed when routing is turned off. This avoids repeating macOS approval and is normal.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                IMDSSystemExtensionGuidance(status: imdsProxyController.systemExtensionStatus)

                if let errorMessage = imdsProxyController.errorMessage,
                   !systemExtensionGuidanceShowsFailure {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.danger)
                }

                if imdsProxyController.isInstalled {
                    Button("Recreate Routing Configuration…") {
                        Task { await runtimeCoordinator.repairDefaultEndpoint() }
                    }
                    .disabled(imdsProxyController.isChangingInstallation)
                    .help("Replace Quorra’s saved macOS network configuration with a fresh copy")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("IMDS")
        .task {
            await imdsProxyController.refresh()
        }
    }

    private var systemExtensionGuidanceShowsFailure: Bool {
        if case .failed = imdsProxyController.systemExtensionStatus {
            return true
        }
        return false
    }
}

private struct IMDSIntegrationStatusPath: View {
    let extensionStatus: IMDSSystemExtensionStatus
    let routingStatus: IMDSProxyController.ConnectionStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusRow(
                title: "System extension",
                value: extensionStatus.description,
                systemImage: "shield.lefthalf.filled",
                color: extensionColor
            )

            Rectangle()
                .fill(connectorColor.opacity(0.45))
                .frame(width: 2, height: 14)
                .padding(.leading, 10)

            statusRow(
                title: "Routing configuration",
                value: routingStatus.description,
                systemImage: "arrow.triangle.branch",
                color: routingColor
            )
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private func statusRow(
        title: String,
        value: String,
        systemImage: String,
        color: Color
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(title)
            Spacer(minLength: 16)
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private var extensionColor: Color {
        switch extensionStatus {
        case .activated:
            return .green
        case .awaitingApproval, .restartRequired:
            return Theme.warn
        case .failed:
            return Theme.danger
        case .notRequested, .activating:
            return Theme.accent
        }
    }

    private var routingColor: Color {
        switch routingStatus {
        case .connected:
            return .green
        case .connecting, .disconnecting:
            return Theme.warn
        case .disconnected:
            return Theme.accent
        case .notInstalled:
            return .secondary
        }
    }

    private var connectorColor: Color {
        routingStatus == .notInstalled ? .secondary : Theme.accent
    }
}

#if DEBUG

#Preview {
    IMDSSettingsTab()
        .environment(AppRuntimeCoordinator.preview())
        .environment(IMDSProxyController())
        .frame(width: 560)
}

#endif
