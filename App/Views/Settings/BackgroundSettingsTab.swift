import SwiftUI

struct BackgroundSettingsTab: View {
    @Environment(AppPresentationController.self) private var presentationController
    @Environment(LaunchAtLoginController.self) private var launchAtLoginController
    @State private var cliInstallation = CLIInstallationController()

    var body: some View {
        Form {
            Section("App presence") {
                Toggle(
                    "Keep Quorra in the Dock",
                    isOn: Binding(
                        get: { !presentationController.runsInMenuBarOnly },
                        set: { presentationController.setRunsInMenuBarOnly(!$0) }
                    )
                )

                Text("When off, Quorra hides its Dock icon after you close its last window and continues running in the menu bar. Opening Quorra always shows its Dock icon.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle(
                    "Launch Quorra at login",
                    isOn: Binding(
                        get: { launchAtLoginController.isRequested },
                        set: { launchAtLoginController.setEnabled($0) }
                    )
                )

                launchAtLoginStatus
            }

            Section("Command-line tool") {
                cliInstallationSection
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Background")
        .task {
            cliInstallation.refresh()
            launchAtLoginController.refresh()
        }
    }

    @ViewBuilder private var launchAtLoginStatus: some View {
        if !presentationController.runsInMenuBarOnly && launchAtLoginController.isRequested {
            Text("Quorra will also open its main window at login. Turn off Keep Quorra in the Dock for a quiet background launch.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        switch launchAtLoginController.status {
        case .requiresApproval:
            Label(
                "Allow Quorra in System Settings to finish enabling launch at login.",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(Theme.warn)
            Button("Open Login Items Settings") {
                launchAtLoginController.openSystemSettings()
            }
        case .notRegistered, .notFound, .enabled:
            EmptyView()
        }

        if let errorMessage = launchAtLoginController.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .foregroundStyle(Theme.danger)
        }
    }

    @ViewBuilder private var cliInstallationSection: some View {
        Text("Install a stable “quorra” command that always runs the CLI included with the current app.")
            .font(.callout)
            .foregroundStyle(.secondary)

        Text("Your shell must include the selected folder in PATH.")
            .font(.caption)
            .foregroundStyle(.tertiary)

        switch cliInstallation.status {
        case .unavailable:
            Label("The command-line tool is unavailable in this build.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Theme.warn)
        case .notInstalled:
            LabeledContent("Status", value: "Not installed")
            Button("Set Up…") { Task { await chooseCLIInstallFolder() } }
        case .installed(let url):
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            commandPath(url)
            Button("Remove", role: .destructive) { cliInstallation.uninstall() }
        case .repairNeeded(let url):
            Label("The command link needs repair.", systemImage: "wrench.and.screwdriver")
                .foregroundStyle(Theme.warn)
            commandPath(url)
            HStack {
                Button("Repair") { cliInstallation.repair() }
                Button("Choose Another Folder…") { Task { await chooseCLIInstallFolder() } }
            }
        case .conflict(let url):
            Label("Another item already uses this command path. Quorra won’t replace it.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Theme.warn)
            commandPath(url, label: "Conflict")
            Button("Choose Another Folder…") { Task { await chooseCLIInstallFolder() } }
        case .accessRequired(let url):
            Label("Quorra no longer has access to the installation folder.", systemImage: "lock.trianglebadge.exclamationmark")
                .foregroundStyle(Theme.warn)
            commandPath(url)
            Button("Choose Folder Again…") { Task { await chooseCLIInstallFolder() } }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(Theme.danger)
            HStack {
                Button("Try Again") { cliInstallation.refresh() }
                Button("Choose Another Folder…") { Task { await chooseCLIInstallFolder() } }
            }
        }
    }

    private func commandPath(_ url: URL, label: String = "Command") -> some View {
        LabeledContent(label) {
            Text(url.path(percentEncoded: false))
                .font(.body.monospaced())
                .textSelection(.enabled)
        }
    }

    private func chooseCLIInstallFolder() async {
        guard let directory = await FolderPicker.pickCLIInstallFolder() else { return }
        cliInstallation.install(in: directory)
    }
}

#if DEBUG

#Preview {
    BackgroundSettingsTab()
        .environment(AppPresentationController())
        .environment(LaunchAtLoginController())
        .frame(width: 560)
}

#endif
