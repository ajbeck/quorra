import AppKit
import AWSConfigINI
import SwiftUI

struct GeneralSettingsTab: View {
    @Environment(AppModel.self) private var appModel
    @Environment(EditorState.self) private var editorState
    @State private var pendingMode: ManagedMode?

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
    }

    private var modeBlurb: String {
        switch appModel.mode {
        case .managed:  return "Quorra modifies ~/.aws/config and ~/.aws/credentials when you save changes."
        case .readOnly: return "Quorra never writes to your AWS files. Profiles are read-only."
        }
    }

    @ViewBuilder private var folderRow: some View {
        switch appModel.phase {
        case .ready(let url):
            LabeledContent("Path", value: url.path(percentEncoded: false))
            Button("Change Folder…") { Task { await changeFolder() } }
        case .setup, .error:
            Text("Folder access not granted. Re-launch the app to set up.")
                .foregroundStyle(.secondary)
        }
    }

    private func changeFolder() async {
        guard let picked = await FolderPicker.pickAWSFolder() else { return }
        await appModel.completeSetup(selectedFolder: picked, mode: appModel.mode)
    }
}

#Preview("General – ready") {
    GeneralSettingsTab()
        .environment(AppModel(initialPhase: .ready(URL(filePath: "/Users/example/.aws"))))
        .environment(EditorState())
        .frame(width: 540)
}

#Preview("General – setup") {
    GeneralSettingsTab()
        .environment(AppModel(initialPhase: .setup))
        .environment(EditorState())
        .frame(width: 540)
}
