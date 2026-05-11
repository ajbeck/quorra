import AppKit
import AWSConfigINI
import SwiftUI

struct GeneralSettingsTab: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Form {
            Section("AWS Folder") {
                folderRow
            }
            Section("Mode") {
                Picker("Quorra can", selection: Binding(
                    get: { appModel.mode },
                    set: { newValue in Task { await appModel.setMode(newValue) } }
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
        .frame(width: 540)
}

#Preview("General – setup") {
    GeneralSettingsTab()
        .environment(AppModel(initialPhase: .setup))
        .frame(width: 540)
}
