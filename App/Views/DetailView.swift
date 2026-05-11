import SwiftUI

struct DetailView: View {
    let selection: SidebarSelection?
    @Environment(ProfilesModel.self) private var profilesModel

    var body: some View {
        switch profilesModel.loadState {
        case .idle, .loading:
            ProgressView().controlSize(.small)
        case .failed(let error):
            ContentUnavailableView(
                "Couldn't load profiles",
                systemImage: "exclamationmark.triangle",
                description: Text(error.localizedDescription)
            )
        case .loaded:
            switch selection {
            case .none:
                ContentUnavailableView("Select a profile or session", systemImage: "sidebar.leading")
            case .session(let name):
                Text("Session: \(name) (stub — phase 8)")
            case .profile(let name):
                Text("Profile: \(name) (stub — phase 8)")
            }
        }
    }
}

#Preview("Detail – loaded, no selection") {
    DetailViewPreviewHarness(selection: nil)
}

#Preview("Detail – loaded, profile selected") {
    DetailViewPreviewHarness(selection: .profile(name: "dev"))
}

private struct DetailViewPreviewHarness: View {
    let selection: SidebarSelection?
    @State private var profilesModel = ProfilesModel()

    var body: some View {
        DetailView(selection: selection)
            .environment(profilesModel)
            .task {
                let tmp = FileManager.default.temporaryDirectory
                    .appending(path: UUID().uuidString, directoryHint: .isDirectory)
                try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                await profilesModel.load(folder: tmp)
            }
    }
}
