import AppKit
import QuorraAppLogic
import SwiftUI

struct QuorraMenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    let appUpdater: AppUpdater
    let presentationController: AppPresentationController
    let runtimeCoordinator: AppRuntimeCoordinator
    let imdsModel: IMDSModel
    let notificationCoordinator: DefaultIMDSNotificationCoordinator

    private var endpointState: IMDSEndpointState {
        imdsModel.state(forEndpointID: DefaultIMDSEndpoint.stableIDString)
    }

    var body: some View {
        Label(endpointStatusTitle, systemImage: endpointStatusImage)
            .disabled(true)

        if let profileName = runtimeCoordinator.defaultEndpointProfileName {
            Text("Serving profile: \(profileName)")
                .disabled(true)
        }

        Button(endpointActionTitle) {
            Task {
                await runtimeCoordinator.setDefaultEndpointEnabled(!endpointState.isActive)
            }
        }
        .disabled(endpointState.isStarting || runtimeCoordinator.defaultEndpointProfileName == nil)

        if !runtimeCoordinator.activeSignIns.isEmpty {
            Divider()

            Label("IAM Identity Center sign-in in progress", systemImage: "person.badge.clock")
                .disabled(true)

            ForEach(runtimeCoordinator.activeSignIns, id: \.sessionName) { progress in
                Button {
                    runtimeCoordinator.openAuthenticationPage(for: progress.sessionName)
                } label: {
                    Label("Open sign-in for \(progress.sessionName)", systemImage: "safari")
                }

                Text("Code \(progress.userCode) · expires \(progress.expiresAt.formatted(date: .omitted, time: .shortened))")
                    .disabled(true)
            }
        }

        Divider()

        Button("Open Quorra") {
            presentMainWindow()
        }
        .keyboardShortcut("o")

        Button("Open Default IMDS Endpoint") {
            notificationCoordinator.requestEndpointOpen()
            presentMainWindow()
        }

        Divider()

        Toggle(
            "Show Quorra in Dock",
            isOn: Binding(
                get: { !presentationController.runsInMenuBarOnly },
                set: { presentationController.setRunsInMenuBarOnly(!$0) }
            )
        )

        SettingsLink()

        Button("Check for Updates…") {
            appUpdater.checkForUpdates()
        }

        Divider()

        Button("Quit Quorra") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var endpointStatusTitle: String {
        switch endpointState {
        case .inactive:
            return "Default Endpoint Off"
        case .starting:
            return "Starting Default Endpoint…"
        case .active:
            return "Default Endpoint Running"
        case .failed:
            return "Default Endpoint Needs Attention"
        }
    }

    private var endpointStatusImage: String {
        switch endpointState {
        case .inactive:
            return "circle"
        case .starting:
            return "ellipsis.circle"
        case .active:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var endpointActionTitle: String {
        endpointState.isActive ? "Stop Default Endpoint" : "Start Default Endpoint"
    }

    private func presentMainWindow() {
        openWindow(id: QuorraSceneID.mainWindow)
        NSApplication.shared.activate()
    }
}
