import AWSConfigINI
import QuorraAppLogic
import SwiftUI

struct GeneralSettingsTab: View {
    @Environment(AppModel.self) private var appModel
    @Environment(EditorState.self) private var editorState
    @State private var pendingMode: ManagedMode?

    var body: some View {
        Form {
            Section("AWS configuration") {
                folderRow
            }

            Section("File access") {
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
                    Text("Edit and manage").tag(ManagedMode.managed)
                    Text("Read only").tag(ManagedMode.readOnly)
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
            Button("Discard and switch", role: .destructive) {
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
        case .managed:
            return "Quorra updates the AWS configuration and credentials files when you save changes."
        case .readOnly:
            return "Quorra reads your AWS files without changing them."
        }
    }

    @ViewBuilder private var folderRow: some View {
        switch appModel.phase {
        case .ready(let url):
            LabeledContent("Folder") {
                Text(url.path(percentEncoded: false))
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            Button("Choose Folder…") { Task { await changeFolder() } }
        case .restoring, .setup, .error:
            Text("Folder access hasn’t been granted. Reopen Quorra to complete setup.")
                .foregroundStyle(.secondary)
        }
    }

    private func changeFolder() async {
        guard let picked = await FolderPicker.pickAWSFolder() else { return }
        await appModel.completeSetup(selectedFolder: picked, mode: appModel.mode)
    }
}

#if DEBUG

#Preview("General – ready") {
    GeneralSettingsTab()
        .environment(AppModel(initialPhase: .ready(URL(filePath: "/Users/example/.aws"))))
        .environment(EditorState())
        .frame(width: 560)
}

#Preview("General – setup") {
    GeneralSettingsTab()
        .environment(AppModel(initialPhase: .setup))
        .environment(EditorState())
        .frame(width: 560)
}

#endif
