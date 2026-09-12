import AppKit
import AWSConfigINI
import QuorraAppLogic
import SwiftUI

struct GeneralSettingsTab: View {
    @Environment(AppModel.self) private var appModel
    @Environment(EditorState.self) private var editorState
    @Environment(AppPresentationController.self) private var presentationController
    @Environment(LaunchAtLoginController.self) private var launchAtLoginController
    @Environment(IMDSProxyController.self) private var imdsProxyController
    @State private var pendingMode: ManagedMode?
    @State private var cliInstallation = CLIInstallationController()

    var body: some View {
        Form {
            Section("AWS Folder") {
                folderRow
            }
            Section("Mode") {
                Picker("Quorra can", selection: Binding(
                    get: { appModel.mode },
                    set: { newValue in
                        if editorState.dirtyDescription != nil && newValue != appModel.mode {
                            pendingMode = newValue
                        } else {
                            Task { await appModel.setMode(newValue) }
                        }
                    }
                )) {
                    Text("Edit & Manage").tag(ManagedMode.managed)
                    Text("Read Only").tag(ManagedMode.readOnly)
                }
                .pickerStyle(.radioGroup)

                Text(modeBlurb)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Menu Bar") {
                Toggle(
                    "Run in the menu bar only",
                    isOn: Binding(
                        get: { presentationController.runsInMenuBarOnly },
                        set: { presentationController.setRunsInMenuBarOnly($0) }
                    )
                )

                Text("Hides Quorra from the Dock and opens its main window only when you choose Open Quorra from the menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle(
                    "Launch Quorra at login",
                    isOn: Binding(
                        get: { launchAtLoginController.isRequested },
                        set: { launchAtLoginController.setEnabled($0) }
                    )
                )
                .disabled(launchAtLoginController.status == .notFound)

                launchAtLoginStatus
            }
            Section("Command Line Tool") {
                cliInstallationSection
            }
            Section("System Metadata Endpoint") {
                systemMetadataEndpointSection
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .confirmationDialog(
            "You have unsaved changes",
            isPresented: Binding(
                get: { pendingMode != nil },
                set: { if !$0 { pendingMode = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Discard & Switch", role: .destructive) {
                if let mode = pendingMode {
                    Task { await appModel.setMode(mode) }
                    editorState.dirtyDescription = nil
                    pendingMode = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingMode = nil }
        } message: {
            Text(editorState.dirtyDescription ?? "")
        }
        .task {
            cliInstallation.refresh()
            launchAtLoginController.refresh()
            await imdsProxyController.refresh()
        }
    }

    @ViewBuilder private var systemMetadataEndpointSection: some View {
        Toggle(
            "Enable the default EC2 metadata URL",
            isOn: Binding(
                get: { imdsProxyController.isInstalled },
                set: { shouldInstall in
                    Task { await imdsProxyController.setInstalled(shouldInstall) }
                }
            )
        )

        Text("Quorra asks macOS to route only TCP connections for 169.254.169.254:80 through its Network Extension. The extension relays opaque bytes to Quorra’s sandboxed IMDSv2 server and never interprets, stores, or logs credentials or tokens.")
            .font(.callout)
            .foregroundStyle(.secondary)

        if imdsProxyController.isInstalled {
            LabeledContent("Network Extension", value: imdsProxyController.connectionStatus.description)
        }

        if let errorMessage = imdsProxyController.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    private var modeBlurb: String {
        switch appModel.mode {
        case .managed:  return "Quorra modifies ~/.aws/config and ~/.aws/credentials when you save changes."
        case .readOnly: return "Quorra never writes to your AWS files. Profiles are read-only."
        }
    }

    @ViewBuilder private var launchAtLoginStatus: some View {
        if !presentationController.runsInMenuBarOnly && launchAtLoginController.isRequested {
            Text("Quorra will also open its main window at login. Turn on menu-bar-only mode for a quiet background launch.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        switch launchAtLoginController.status {
        case .requiresApproval:
            Label("Allow Quorra in System Settings to finish enabling launch at login.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Button("Open Login Items Settings") {
                launchAtLoginController.openSystemSettings()
            }
        case .notFound:
            Label("Launch at login is unavailable in this build.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .notRegistered, .enabled:
            EmptyView()
        }

        if let errorMessage = launchAtLoginController.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder private var folderRow: some View {
        switch appModel.phase {
        case .ready(let url):
            LabeledContent("Path", value: url.path(percentEncoded: false))
            Button("Change Folder…") { Task { await changeFolder() } }
        case .restoring, .setup, .error:
            Text("Folder access not granted. Re-launch the app to set up.")
                .foregroundStyle(.secondary)
        }
    }

    private func changeFolder() async {
        guard let picked = await FolderPicker.pickAWSFolder() else { return }
        await appModel.completeSetup(selectedFolder: picked, mode: appModel.mode)
    }

    @ViewBuilder private var cliInstallationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Install a stable “quorra” command for Terminal. It always runs the CLI included with the current Quorra app.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("Your shell must include the selected folder in PATH.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            switch cliInstallation.status {
            case .unavailable:
                Label("The command-line tool is unavailable in this build.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .notInstalled:
                Label("Not installed", systemImage: "terminal")
                Button("Set Up…") { Task { await chooseCLIInstallFolder() } }
            case .installed(let url):
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                LabeledContent("Command", value: url.path(percentEncoded: false))
                Button("Remove", role: .destructive) { cliInstallation.uninstall() }
            case .repairNeeded(let url):
                Label("The command link needs repair.", systemImage: "wrench.and.screwdriver")
                    .foregroundStyle(.orange)
                LabeledContent("Command", value: url.path(percentEncoded: false))
                HStack {
                    Button("Repair") { cliInstallation.repair() }
                    Button("Choose Another Folder…") { Task { await chooseCLIInstallFolder() } }
                }
            case .conflict(let url):
                Label("Another item already uses this command path. Quorra won’t replace it.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                LabeledContent("Conflict", value: url.path(percentEncoded: false))
                Button("Choose Another Folder…") { Task { await chooseCLIInstallFolder() } }
            case .accessRequired(let url):
                Label("Quorra no longer has access to the installation folder.", systemImage: "lock.trianglebadge.exclamationmark")
                    .foregroundStyle(.orange)
                LabeledContent("Command", value: url.path(percentEncoded: false))
                Button("Choose Folder Again…") { Task { await chooseCLIInstallFolder() } }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                HStack {
                    Button("Try Again") { cliInstallation.refresh() }
                    Button("Choose Another Folder…") { Task { await chooseCLIInstallFolder() } }
                }
            }
        }
    }

    private func chooseCLIInstallFolder() async {
        guard let directory = await FolderPicker.pickCLIInstallFolder() else { return }
        cliInstallation.install(in: directory)
    }
}

#if DEBUG

#Preview("General – ready") {
    GeneralSettingsTab()
        .environment(AppModel(initialPhase: .ready(URL(filePath: "/Users/example/.aws"))))
        .environment(EditorState())
        .environment(AppPresentationController())
        .environment(LaunchAtLoginController())
        .environment(IMDSProxyController())
        .frame(width: 540)
}

#Preview("General – setup") {
    GeneralSettingsTab()
        .environment(AppModel(initialPhase: .setup))
        .environment(EditorState())
        .environment(AppPresentationController())
        .environment(LaunchAtLoginController())
        .environment(IMDSProxyController())
        .frame(width: 540)
}

#endif
