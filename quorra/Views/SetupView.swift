import SwiftUI

struct SetupView: View {
    @Environment(AppModel.self) private var appModel
    @State private var pendingFolder: URL?
    @State private var showingNonStandardWarning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            featureBullets
            Spacer()
            chooseFolderButton
        }
        .padding(40)
        .frame(minWidth: 520, minHeight: 420)
        .alert(
            "Non-standard AWS folder",
            isPresented: $showingNonStandardWarning,
            presenting: pendingFolder
        ) { folder in
            Button("Continue") {
                Task { await appModel.completeSetup(selectedFolder: folder) }
            }
            Button("Choose Another…") {
                pendingFolder = nil
                Task { await pickFolder() }
            }
            Button("Cancel", role: .cancel) {
                pendingFolder = nil
            }
        } message: { folder in
            Text("You selected \(folder.path(percentEncoded: false)). AWS SDKs only read ~/.aws by default — make sure AWS_CONFIG_FILE is set to point at this folder.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Welcome to Quorra")
                .font(.largeTitle.weight(.semibold))
            Text("A local manager for your AWS credentials.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var featureBullets: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Reads and writes your ~/.aws configuration", systemImage: "doc.text")
            Label("Stores secrets in the macOS Keychain", systemImage: "lock.shield")
            Label("Runs a local IMDS endpoint for your shell", systemImage: "server.rack")
            Label("Provides a CLI for credential_process integrations", systemImage: "terminal")
        }
        .font(.body)
    }

    private var chooseFolderButton: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("To begin, grant Quorra access to your AWS folder. The default location is ~/.aws.")
                .foregroundStyle(.secondary)
            Button {
                Task { await pickFolder() }
            } label: {
                Label("Choose AWS Folder…", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func pickFolder() async {
        guard let picked = await FolderPicker.pickAWSFolder() else { return }

        if picked.standardizedFileURL == Self.defaultAWSFolder.standardizedFileURL {
            await appModel.completeSetup(selectedFolder: picked)
        } else {
            pendingFolder = picked
            showingNonStandardWarning = true
        }
    }

    private static var defaultAWSFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".aws")
    }
}

#Preview("Setup") {
    SetupView()
        .environment(AppModel(initialPhase: .setup))
}
