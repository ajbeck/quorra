import AWSConfigINI
import QuorraAppLogic
import SwiftUI

struct GeneralSettingsTab: View {
    @Environment(AppModel.self) private var appModel
    @Environment(IdentityExportCoordinator.self) private var exportCoordinator

    var body: some View {
        Form {
            Section("AWS configuration") {
                folderRow
            }

            Section("Export") {
                Toggle("Export to AWS folder", isOn: exportEnabled)

                Text(exportBlurb)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let failure = exportCoordinator.lastExportFailure {
                    LabeledContent {
                        Button("Retry") {
                            Task { await exportCoordinator.exportIfEnabled() }
                        }
                        .disabled(exportCoordinator.isExporting)
                    } label: {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }

    /// Turning export on writes the whole store once so the file catches up with edits made while it was off.
    private var exportEnabled: Binding<Bool> {
        Binding(
            get: { appModel.mode == .managed },
            set: { isOn in
                Task {
                    await appModel.setMode(isOn ? .managed : .readOnly)
                    if isOn {
                        await exportCoordinator.exportIfEnabled()
                    }
                }
            }
        )
    }

    private var exportBlurb: String {
        switch appModel.mode {
        case .managed:
            return "Quorra writes the sessions and profiles you manage here into the AWS config file so the AWS CLI and SDKs can use them. Other sections and keys are kept."
        case .readOnly:
            return "Quorra keeps the sessions and profiles in the app only and never writes to your AWS files."
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
            HStack {
                Button("Choose Folder…") { Task { await changeFolder() } }
                Button("Re-import from AWS Folder") { Task { await exportCoordinator.reimport() } }
                    .disabled(exportCoordinator.isImporting)
            }
            if let message = exportCoordinator.lastImportMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
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
        .environment(IdentityExportCoordinator.preview(importMessage: "Imported 1 session and 5 profiles."))
        .frame(width: 560)
}

#Preview("General – export failed") {
    GeneralSettingsTab()
        .environment(AppModel(initialPhase: .ready(URL(filePath: "/Users/example/.aws"))))
        .environment(IdentityExportCoordinator.preview(failure: "You don’t have permission to save the file “config” in the folder “.aws”."))
        .frame(width: 560)
}

#Preview("General – setup") {
    GeneralSettingsTab()
        .environment(AppModel(initialPhase: .setup))
        .environment(IdentityExportCoordinator.preview())
        .frame(width: 560)
}

#endif
