import SwiftUI

struct FolderContentsView: View {
    let folderURL: URL

    @State private var loadState: LoadState = .loading

    var body: some View {
        content
            .task(id: folderURL) {
                await load()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            ProgressView().controlSize(.small)
        case .loaded(let entries) where entries.isEmpty:
            ContentUnavailableView(
                "Empty folder",
                systemImage: "folder",
                description: Text("This folder doesn't contain any files yet.")
            )
        case .loaded(let entries):
            List(entries) { entry in
                Label(entry.name, systemImage: entry.isDirectory ? "folder" : "doc")
            }
        case .failed(let message):
            ContentUnavailableView(
                "Couldn't read folder",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }

    private func load() async {
        loadState = .loading
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
            let entries = urls
                .map(Entry.init(url:))
                .sorted(by: Entry.sortOrder)
            loadState = .loaded(entries)
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    private enum LoadState {
        case loading
        case loaded([Entry])
        case failed(String)
    }

    private struct Entry: Identifiable {
        let url: URL
        let name: String
        let isDirectory: Bool

        var id: URL { url }

        init(url: URL) {
            self.url = url
            self.name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            self.isDirectory = values?.isDirectory ?? false
        }

        static func sortOrder(_ a: Entry, _ b: Entry) -> Bool {
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

#Preview("Folder contents – home directory") {
    FolderContentsView(folderURL: FileManager.default.homeDirectoryForCurrentUser)
        .frame(width: 420, height: 400)
}
