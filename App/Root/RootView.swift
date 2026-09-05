import SwiftUI
import QuorraAppLogic

struct RootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            switch appModel.phase {
            case .restoring:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .setup:
                SetupView()
            case .ready(let url):
                MainView(folderURL: url)
            case .error(let err):
                ErrorView(error: err)
            }
        }
        .task {
            #if DEBUG
            guard !ProcessInfo.processInfo.isRunningForPreviews else { return }
            #endif
            await appModel.resolveStoredBookmark()
        }
    }
}

#if DEBUG
extension ProcessInfo {
    var isRunningForPreviews: Bool {
        environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
}
#endif

#if DEBUG

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

#endif
