import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            switch appModel.phase {
            case .setup:
                SetupView()
            case .ready(let url):
                MainView(folderURL: url)
            case .error(let err):
                ErrorView(error: err)
            }
        }
        .task {
            await appModel.resolveStoredBookmark()
        }
    }
}

#Preview("Root – setup") {
    RootView()
        .environment(AppModel(initialPhase: .setup))
}

#Preview("Root – ready") {
    let url = URL(filePath: "/Users/example/.aws")
    RootView()
        .environment(AppModel(initialPhase: .ready(url)))
}

#Preview("Root – error") {
    RootView()
        .environment(AppModel(initialPhase: .error(.folderMissing)))
}
