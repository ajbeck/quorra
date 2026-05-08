import SwiftUI

struct MainView: View {
    let folderURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            FolderContentsView(folderURL: folderURL)
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 400)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AWS Folder")
                .font(.title2.weight(.semibold))
            Text(folderURL.path(percentEncoded: false))
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

#Preview("Main – home directory") {
    MainView(folderURL: FileManager.default.homeDirectoryForCurrentUser)
        .environment(AppModel(initialPhase: .ready(FileManager.default.homeDirectoryForCurrentUser)))
}
